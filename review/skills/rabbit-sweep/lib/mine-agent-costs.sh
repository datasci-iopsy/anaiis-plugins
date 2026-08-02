#!/usr/bin/env bash
# mine-agent-costs.sh: retroactive agent cost and concurrency mining from Claude Code session
# transcripts. Operationalizes the 2026-08-02 manual investigation (spec 2.7) as a repeatable
# tool instead of a one-off. Answers the agent-topology question: per subagent_type, how many
# calls, how long, how many tool-uses, how many tokens -- plus whether concurrent dispatch in
# practice ever touches the same file (it should not).
#
# Read-only; never invokes the CodeRabbit CLI or any live agent.
# Usage: mine-agent-costs.sh [--project <name-or-substring>]
# Output: $OUT_DIR/agent-costs.json, $OUT_DIR/agent-costs.md, summary on stdout.
# PROJECTS_ROOT/OUT_DIR are overridable via env for isolated smoke testing.

set -euo pipefail

PROJECTS_ROOT="${MINE_PROJECTS_ROOT:-${HOME}/.claude/projects}"
OUT_DIR="${MINE_OUT_DIR:-${HOME}/.claude/rabbit-sweep/analysis}"
PROJECT_FILTER=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--project)
			PROJECT_FILTER="${2:-}"
			shift 2
			;;
		*)
			printf 'Usage: mine-agent-costs.sh [--project <name-or-substring>]\n' >&2
			exit 1
			;;
	esac
done

mkdir -p "$OUT_DIR"

TMP_WORK=$(mktemp -d)
trap 'rm -rf "$TMP_WORK"' EXIT

# --- Resolve the target project directory ----------------------------------
# Claude Code names a project directory by replacing every "/" in the cwd with "-". Given a
# short --project name (e.g. "anaiis-plugins") that isn't already in that form, match it as a
# substring of the directory's own name; this matches the human-friendly form shown in this
# skill's own documented usage. Falls back to the current directory's own transcript
# directory when no --project is given.
if [ -n "$PROJECT_FILTER" ]; then
	project_dirs=$(find "$PROJECTS_ROOT" -mindepth 1 -maxdepth 1 -type d -name "*${PROJECT_FILTER}*" 2>/dev/null)
else
	default_dir="${PROJECTS_ROOT}/$(pwd | tr '/' '-')"
	project_dirs=""
	[ -d "$default_dir" ] && project_dirs="$default_dir"
fi

if [ -z "$project_dirs" ]; then
	printf '[]\n' >"${OUT_DIR}/agent-costs.json"
	printf '# agent-costs\n\nNo matching project directory found under %s.\n' "$PROJECTS_ROOT" >"${OUT_DIR}/agent-costs.md"
	printf 'No matching project directory found under %s.\n' "$PROJECTS_ROOT"
	exit 0
fi

calls_ndjson="${TMP_WORK}/calls.ndjson"
notifs_ndjson="${TMP_WORK}/notifs.ndjson"
immediate_ndjson="${TMP_WORK}/immediate.ndjson"
: >"$calls_ndjson"
: >"$notifs_ndjson"
: >"$immediate_ndjson"

while IFS= read -r project_dir; do
	[ -z "$project_dir" ] && continue
	for f in "${project_dir}"/*.jsonl; do
		[ -f "$f" ] || continue
		fname=$(basename "$f")

		# Agent() dispatches: one row per tool_use block named "Agent". file_hint is a
		# best-effort heuristic (last token in the description matching a common code/doc
		# extension) -- Agent() carries no structured target-file field, only free-text
		# description, so this is a signal for the same-file/cross-file breakdown below, not a
		# guarantee. A call whose description names no recognizable file yields null and is
		# reported as "unknown", never silently folded into either same-file or cross-file.
		jq -c --arg fn "$fname" '
			select(.message.content | type == "array") | . as $line
			| ($line.message.content[] | select(.type=="tool_use" and .name=="Agent")) as $a
			| {file:$fn, uuid:$line.uuid, ts:($line.timestamp|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601),
			   id:$a.id, subtype:$a.input.subagent_type,
			   file_hint: ($a.input.description // "" | [scan("[A-Za-z0-9_.-]+\\.(?:sh|md|json|py|yaml|yml|R|js|ts)")] | last)}
		' "$f" 2>/dev/null >>"$calls_ndjson" || true

		# task-notification completions (async): duration_ms/tool_uses/subagent_tokens usage
		# block. Also fires for backgrounded non-Agent tools (e.g. a backgrounded Bash
		# command); those simply carry no usage fields and are filtered out downstream.
		jq -c --arg fn "$fname" '
			select(.message.content | type == "string") | select(.message.content | test("task-notification"))
			| {file:$fn, note_ts:(.timestamp|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601),
			   tuid:(.message.content|capture("<tool-use-id>(?<v>[^<]+)</tool-use-id>").v),
			   dur_ms:(.message.content|capture("<duration_ms>(?<v>[0-9]+)</duration_ms>").v // null),
			   tool_uses:(.message.content|capture("<tool_uses>(?<v>[0-9]+)</tool_uses>").v // null),
			   tokens:(.message.content|capture("<subagent_tokens>(?<v>[0-9]+)</subagent_tokens>").v // null)}
		' "$f" 2>/dev/null >>"$notifs_ndjson" || true

		# Immediate tool_result acks: distinguishes an async dispatch ("Async agent
		# launched...") from a synchronous one (the real result returned directly).
		jq -c --arg fn "$fname" '
			select(.message.content | type == "array") | . as $line
			| ($line.message.content[] | select(.type=="tool_result")) as $r
			| {file:$fn, id:$r.tool_use_id, is_async: ((($r.content[0].text // "")|test("Async agent launched")))}
		' "$f" 2>/dev/null >>"$immediate_ndjson" || true
	done
done <<<"$project_dirs"

# Dedupe by tool_use id BEFORE anything else. A forked/resumed session shares a prefix of
# tool_use blocks with the session it forked from (confirmed live in this corpus: session
# 2d458711 shared 14/14 Agent calls with 55e484ef); without this, both raw totals and the cost
# table below silently double-count.
jq -s 'unique_by(.id)' "$calls_ndjson" >"${TMP_WORK}/calls-dedup.json"
jq -s 'group_by(.tuid) | map(.[0])' "$notifs_ndjson" >"${TMP_WORK}/notifs-dedup.json"
jq -s 'group_by(.id) | map(.[0])' "$immediate_ndjson" >"${TMP_WORK}/immediate-dedup.json"

n_calls=$(jq 'length' "${TMP_WORK}/calls-dedup.json")

# --- Ground-truth cost per subagent_type, from task-notification usage blocks only ---------
jq --slurpfile calls "${TMP_WORK}/calls-dedup.json" '
	map(select(.dur_ms != null)) as $valid
	| ($calls[0] | map({(.id): .subtype}) | add) as $subtype_by_id
	| [$valid[] | . + {subtype: ($subtype_by_id[.tuid] // "unknown")}]
	| group_by(.subtype) | map({
		subtype: .[0].subtype,
		n: length,
		dur_ms_min: (map(.dur_ms|tonumber) | min),
		dur_ms_median: (map(.dur_ms|tonumber) | sort | .[length/2|floor]),
		dur_ms_max: (map(.dur_ms|tonumber) | max),
		tool_uses_median: (map(.tool_uses|tonumber) | sort | .[length/2|floor]),
		avg_tokens: ((map(.tokens|tonumber) | add) / length | floor)
	})
' "${TMP_WORK}/notifs-dedup.json" >"${TMP_WORK}/cost-table.json"

# --- Concurrency, per session file: end_ts is the matched task-notification's timestamp when
# async, else the dispatch's own timestamp when synchronous. Overlap = a later dispatch's
# timestamp falling before an earlier call's end_ts. -----------------------------------------
jq --slurpfile notifs "${TMP_WORK}/notifs-dedup.json" --slurpfile imm "${TMP_WORK}/immediate-dedup.json" '
	($notifs[0] | map({(.tuid): .note_ts}) | add // {}) as $note_by_id
	| ($imm[0] | map({(.id): .is_async}) | add // {}) as $async_by_id
	| [.[] | . + {is_async: ($async_by_id[.id] // false)}]
	| [.[] | . + {end_ts: ($note_by_id[.id] // .ts)}]
	| group_by(.file) | map({
		file: .[0].file,
		n_calls: length,
		sorted: (sort_by(.ts))
	})
	| map(. + {
		overlap_pairs: [range(0; (.sorted|length)) as $i | range($i+1; (.sorted|length)) as $j
			| select(.sorted[$j].ts < .sorted[$i].end_ts)
			| {a_hint: .sorted[$i].file_hint, b_hint: .sorted[$j].file_hint}],
		peak_concurrency: ([range(0; (.sorted|length)) as $i
			| [range(0; (.sorted|length)) as $k | select(.sorted[$k].ts <= .sorted[$i].ts and .sorted[$k].end_ts > .sorted[$i].ts)] | length]
			| if length > 0 then max else 0 end)
	})
	| map(. + {
		overlaps: (.overlap_pairs | length),
		same_file_overlaps: ([.overlap_pairs[] | select(.a_hint != null and .b_hint != null and .a_hint == .b_hint)] | length),
		cross_file_overlaps: ([.overlap_pairs[] | select(.a_hint != null and .b_hint != null and .a_hint != .b_hint)] | length),
		unknown_file_overlaps: ([.overlap_pairs[] | select(.a_hint == null or .b_hint == null)] | length)
	})
	| map({file, n_calls, overlaps, same_file_overlaps, cross_file_overlaps, unknown_file_overlaps, peak_concurrency})
' "${TMP_WORK}/calls-dedup.json" >"${TMP_WORK}/concurrency.json"

cp "${TMP_WORK}/calls-dedup.json" "${OUT_DIR}/agent-costs.json"

{
	printf '# agent-costs\n\n'
	printf 'Total unique agent dispatches: %s\n\n' "$n_calls"
	printf '## Cost per agent type\n\n'
	printf '| Subtype | n | Duration min | Duration median | Duration max | Tool-uses median | Avg tokens |\n'
	printf '|---|---|---|---|---|---|---|\n'
	jq -r '.[] | [.subtype, .n, (.dur_ms_min/1000|floor|tostring)+"s", (.dur_ms_median/1000|floor|tostring)+"s",
		(.dur_ms_max/1000|floor|tostring)+"s", .tool_uses_median, .avg_tokens] | @tsv' "${TMP_WORK}/cost-table.json" \
		| awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7}'
	printf '\n## Concurrency per session\n\n'
	printf 'Same-file/cross-file classification is a best-effort heuristic (a filename token\n'
	printf 'extracted from the description text) -- Agent() carries no structured target-file\n'
	printf 'field. "Unknown" means the heuristic found no recognizable filename on at least one\n'
	printf 'side of the pair; never silently folded into same-file or cross-file.\n\n'
	printf '| Session | Calls | Overlapping pairs | Same-file | Cross-file | Unknown | Peak simultaneous |\n'
	printf '|---|---|---|---|---|---|---|\n'
	jq -r '.[] | [.file, .n_calls, .overlaps, .same_file_overlaps, .cross_file_overlaps, .unknown_file_overlaps, .peak_concurrency] | @tsv' "${TMP_WORK}/concurrency.json" \
		| awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7}'
} >"${OUT_DIR}/agent-costs.md"

printf 'Wrote %s and %s\n' "${OUT_DIR}/agent-costs.json" "${OUT_DIR}/agent-costs.md"
cat "${OUT_DIR}/agent-costs.md"
