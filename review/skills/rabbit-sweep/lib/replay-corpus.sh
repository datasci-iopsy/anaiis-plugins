#!/usr/bin/env bash
# replay-corpus.sh: offline analysis of local CodeRabbit review history and rabbit-sweep
# ledgers. Answers the round-policy question with real data instead of a guess: for each
# multi-round local-mode session, how many findings each round produced, how many were
# accepted and verified, and how many of a later round's findings were re-flags of code a
# prior round's own fix had just written.
#
# Never invokes CodeRabbit or any live agent. Reads only:
#   $REVIEWS_ROOT/**/{git.json,internalState.json,<uuid>.json}   (default ~/.coderabbit/reviews)
#   $LEDGER_ROOT/*.jsonl                                          (default ~/.claude/rabbit-sweep/runs)
#
# Usage: replay-corpus.sh [--session <branch-hash>]
# Output: $OUT_DIR/replay-corpus.json (full data), $OUT_DIR/replay-corpus.md (short table),
#         a summary on stdout (default ~/.claude/rabbit-sweep/analysis). Skipped sessions are
#         always listed with a reason -- never silently dropped.
#
# REVIEWS_ROOT/LEDGER_ROOT/OUT_DIR are overridable via env for isolated smoke testing.

set -euo pipefail

REVIEWS_ROOT="${REPLAY_REVIEWS_ROOT:-${HOME}/.coderabbit/reviews}"
LEDGER_ROOT="${REPLAY_LEDGER_ROOT:-${HOME}/.claude/rabbit-sweep/runs}"
OUT_DIR="${REPLAY_OUT_DIR:-${HOME}/.claude/rabbit-sweep/analysis}"
SESSION_FILTER=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--session)
			SESSION_FILTER="${2:-}"
			shift 2
			;;
		*)
			printf 'Usage: replay-corpus.sh [--session <branch-hash>]\n' >&2
			exit 1
			;;
	esac
done

mkdir -p "$OUT_DIR"

# Re-flag detection compares a finding's line range directly against prior rounds' own
# findings on the same file, not against the fix commit's diff hunks. Confirmed empirically:
# CodeRabbit's startLine/endLine point at the policy or declaration being discussed (e.g. a
# `tools:` frontmatter line), which is frequently NOT the line the fix commit itself touched
# (the fix may add prose in a different section entirely). A diff-hunk-overlap check misses
# this and undercounts re-flags; a same-file, overlapping-or-nearby-line-range check against
# what CodeRabbit itself already flagged does not. Window matches intent-preflight.sh's own
# +-20 convention. Usage: ranges_overlap <s1> <e1> <s2> <e2> <window>
ranges_overlap() {
	local s1="$1" e1="$2" s2="$3" e2="$4" window="${5:-0}"
	local r1_start=$((s1 - window)) r1_end=$((e1 + window))
	[ "$r1_start" -lt 1 ] && r1_start=1
	((r1_start <= e2 && r1_end >= s2))
}

# All round-dirs (repo/branch/reviews/<epoch-ms>) under $REVIEWS_ROOT that have a git.json,
# one path per line, in no particular order -- callers sort per-session by epoch themselves.
find_round_dirs() {
	find "$REVIEWS_ROOT" -mindepth 4 -maxdepth 4 -type d 2>/dev/null | while read -r d; do
		if [ -f "${d}/git.json" ]; then printf '%s\n' "$d"; fi
	done || true
}

# Finds the ledger file whose review_started event's branch matches $1 and whose own start
# time is the closest-preceding match to epoch-ms $2. Prints the path, or nothing if none
# matches. Content-based, not filename-based: ledger filenames use two different conventions
# across this corpus's history (sha1-of-branch and literal-branch-name), so matching on the
# review_started event's own .branch field is the only scheme that works for both.
find_ledger_for_branch() {
	local branch="$1" session_epoch_ms="$2"
	local best="" best_delta=""
	local f started_branch started_ts started_epoch delta
	for f in "${LEDGER_ROOT}"/*.jsonl; do
		[ -f "$f" ] || continue
		started_branch=$(head -1 "$f" | jq -r 'select(.event=="review_started") | .branch' 2>/dev/null) || continue
		[ "$started_branch" = "$branch" ] || continue
		started_ts=$(head -1 "$f" | jq -r '.ts // empty' 2>/dev/null) || continue
		[ -z "$started_ts" ] && continue
		started_epoch=$(date -u -j -f '%Y%m%dT%H%M%SZ' "$started_ts" +%s 2>/dev/null || date -u -d "$started_ts" +%s 2>/dev/null) || continue
		started_epoch=$((started_epoch * 1000))
		delta=$((session_epoch_ms - started_epoch))
		[ "$delta" -lt 0 ] && continue # ledger started after the review; not a candidate
		if [ -z "$best_delta" ] || [ "$delta" -lt "$best_delta" ]; then
			best="$f"
			best_delta="$delta"
		fi
	done
	[ -n "$best" ] && printf '%s\n' "$best"
}

TMP_WORK=$(mktemp -d)
trap 'rm -rf "$TMP_WORK"' EXIT

sessions_json="${TMP_WORK}/sessions.json"
printf '[]\n' >"$sessions_json"

# --- Discover sessions (unique repo/branch directories) --------------------
session_dirs=$(find_round_dirs | while read -r d; do dirname "$(dirname "$d")"; done | sort -u) || true

if [ -z "$session_dirs" ]; then
	printf '[]\n' >"${OUT_DIR}/replay-corpus.json"
	printf '# replay-corpus\n\nNo review sessions found under %s.\n' "$REVIEWS_ROOT" >"${OUT_DIR}/replay-corpus.md"
	printf 'No review sessions found under %s.\n' "$REVIEWS_ROOT"
	exit 0
fi

while IFS= read -r session_dir; do
	[ -z "$session_dir" ] && continue
	branch_hash=$(basename "$session_dir")
	repo_hash=$(basename "$(dirname "$session_dir")")

	if [ -n "$SESSION_FILTER" ] && [ "$branch_hash" != "$SESSION_FILTER" ]; then
		continue
	fi

	# Round dirs for this session only, sorted by epoch-ms (the dir's own basename).
	round_dirs=$(find "${session_dir}/reviews" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
		| while read -r d; do if [ -f "${d}/git.json" ]; then printf '%s\t%s\n' "$(basename "$d")" "$d"; fi; done \
		| sort -n | cut -f2-) || true
	[ -z "$round_dirs" ] && continue

	first_round_dir=$(printf '%s\n' "$round_dirs" | head -1)
	branch=$(jq -r '.currentBranch' "${first_round_dir}/git.json")
	working_dir=$(jq -r '.workingDirectory' "${first_round_dir}/git.json")
	last_round_dir=$(printf '%s\n' "$round_dirs" | tail -1)
	last_head=$(jq -r '.head' "${last_round_dir}/git.json")

	skip_reason=""
	if [ ! -d "$working_dir" ]; then
		skip_reason="workingDirectory does not exist: ${working_dir}"
	elif ! git -C "$working_dir" cat-file -e "${last_head}^{commit}" 2>/dev/null; then
		skip_reason="unresolvable HEAD (${last_head}) in ${working_dir}"
	fi

	ledger=""
	if [ -z "$skip_reason" ]; then
		first_epoch=$(basename "$first_round_dir")
		ledger=$(find_ledger_for_branch "$branch" "$first_epoch" || true)
		[ -z "$ledger" ] && skip_reason="no matching ledger found for branch ${branch}"
	fi

	if [ -n "$skip_reason" ]; then
		jq --arg repo "$repo_hash" --arg branch_hash "$branch_hash" --arg branch "$branch" --arg reason "$skip_reason" \
			'. + [{session: {repo_hash: $repo, branch_hash: $branch_hash, branch: $branch}, skipped: true, skip_reason: $reason}]' \
			"$sessions_json" >"${sessions_json}.tmp" && mv "${sessions_json}.tmp" "$sessions_json"
		continue
	fi

	# --- Per-round data: findings (file/line/severity) + prior fix-diff cache -------------
	rounds_json="${TMP_WORK}/rounds-${branch_hash}.json"
	printf '[]\n' >"$rounds_json"
	round_num=0
	prior_findings_json="${TMP_WORK}/prior-findings-${branch_hash}.json"
	printf '[]\n' >"$prior_findings_json"
	all_prior_findings_json="${TMP_WORK}/all-prior-findings-${branch_hash}.json"
	printf '[]\n' >"$all_prior_findings_json"
	REFLAG_WINDOW=20

	while IFS= read -r round_dir; do
		round_num=$((round_num + 1))
		base_sha=$(jq -r '.baseCommitId' "${round_dir}/git.json")
		head_sha=$(jq -r '.head' "${round_dir}/git.json")

		# Match findings by their UUID filename, not by excluding known metadata files by name.
		# CodeRabbit's own metadata filenames have varied across CLI versions in this corpus's
		# history (diff.json in older reviews, incrementalDiff.json plus diff.json in newer
		# ones, alongside git.json and internalState.json always); an exclusion list silently
		# breaks on the next metadata file a future CLI version adds, where a UUID-only match
		# only ever admits real findings.
		findings_json="${TMP_WORK}/findings-r${round_num}-${branch_hash}.json"
		finding_paths=$(find "$round_dir" -maxdepth 1 -type f \
			-regex '.*/[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}\.json' 2>/dev/null)
		if [ -n "$finding_paths" ]; then
			printf '%s\n' "$finding_paths" | while IFS= read -r fp; do jq -c '.' "$fp"; done | jq -s -c '.' >"$findings_json"
		else
			printf '[]\n' >"$findings_json"
		fi

		# Re-flag detection (round >= 2 only): compares this round's findings directly against
		# every finding from rounds 1..round_num-1 on the same file, within +-REFLAG_WINDOW
		# lines. Confirmed empirically that comparing against the fix commit's own diff hunks
		# undercounts: CodeRabbit's startLine/endLine point at the policy/declaration being
		# discussed (e.g. a `tools:` frontmatter line), not necessarily the line the fix
		# commit itself touched (the fix may add prose in an unrelated section of the file).
		# Contradiction candidates: the same re-flag pairs, but carrying both findings' own
		# text (title) instead of just a count, for a human or a later model-assisted pass to
		# judge whether the later round's remedy actually reverses the earlier one's direction.
		# Deliberately kept out of reflag_count and every other deterministic rate -- judging
		# "did the remedy reverse" is not something this offline script can decide on its own.
		reflag_count=0
		candidates_json="${TMP_WORK}/candidates-r${round_num}-${branch_hash}.json"
		printf '[]\n' >"$candidates_json"
		if [ "$round_num" -ge 2 ]; then
			reflag_count=$(jq -n --slurpfile cur "$findings_json" --slurpfile prior "$all_prior_findings_json" --argjson window "$REFLAG_WINDOW" '
				[$cur[0][] | select(.startLine != null) as $c |
					select([$prior[0][] | select(.startLine != null and .fileName == $c.fileName
						and (($c.startLine - $window) <= .endLine) and (($c.endLine + $window) >= .startLine))
					] | length > 0)
				] | length')
			jq -n --slurpfile cur "$findings_json" --slurpfile prior "$all_prior_findings_json" --argjson window "$REFLAG_WINDOW" '
				[$cur[0][] | select(.startLine != null) as $c |
					($prior[0][] | select(.startLine != null and .fileName == $c.fileName
						and (($c.startLine - $window) <= .endLine) and (($c.endLine + $window) >= .startLine))) as $p |
					{
						current: {fileName: $c.fileName, startLine: $c.startLine, endLine: $c.endLine, title: $c.title},
						prior: {fileName: $p.fileName, startLine: $p.startLine, endLine: $p.endLine, title: $p.title}
					}
				]' >"$candidates_json"
		fi

		# Range escalation: this round's finding range strictly contains a same-file finding
		# range from the immediately preceding round only (not all prior rounds).
		escalation_count=0
		if [ "$round_num" -ge 2 ]; then
			escalation_count=$(jq -n --slurpfile cur "$findings_json" --slurpfile prev "$prior_findings_json" '
				[$cur[0][] as $c | $prev[0][] as $p |
					select($c.fileName == $p.fileName and $c.startLine <= $p.startLine and $c.endLine >= $p.endLine
						and ($c.startLine < $p.startLine or $c.endLine > $p.endLine))
				] | length')
		fi
		cp "$findings_json" "$prior_findings_json"
		jq -s '.[0] + .[1]' "$all_prior_findings_json" "$findings_json" >"${all_prior_findings_json}.tmp" \
			&& mv "${all_prior_findings_json}.tmp" "$all_prior_findings_json"

		total_findings=$(jq 'length' "$findings_json")

		jq --argjson round "$round_num" --arg base "$base_sha" --arg head "$head_sha" \
			--argjson total "$total_findings" --argjson reflags "$reflag_count" --argjson esc "$escalation_count" \
			--slurpfile candidates "$candidates_json" \
			'. + [{round: $round, base_sha: $base, head_sha: $head, findings: $total, reflags: $reflags,
				range_escalations: $esc, contradiction_candidates: $candidates[0]}]' \
			"$rounds_json" >"${rounds_json}.tmp" && mv "${rounds_json}.tmp" "$rounds_json"
	done <<<"$round_dirs"

	# --- Acceptance rate per round, from the ledger, partitioned by round_start position ---
	# grep exits 1 on a ledger with no round_start event at all (older ledgers predate that
	# event type); under set -e this bare assignment would abort the whole script on a
	# legitimate "no matches" outcome, not just a real error, so the pipeline is guarded.
	round_start_lines=$(grep -n '"event":"round_start"' "$ledger" | cut -d: -f1) || true
	total_lines=$(wc -l <"$ledger" | tr -d ' ')
	nrounds=$(jq 'length' "$rounds_json")

	if [ -z "$round_start_lines" ]; then
		# No round_start markers: per-round partitioning is not possible. Mark accepted
		# as unknown instead of reusing the whole-ledger range for every round.
		for ((r = 1; r <= nrounds; r++)); do
			jq --argjson r "$r" '(.[$r-1].accepted) = null' "$rounds_json" >"${rounds_json}.tmp" && mv "${rounds_json}.tmp" "$rounds_json"
		done
	else
		for ((r = 1; r <= nrounds; r++)); do
			start_line=$(printf '%s\n' "$round_start_lines" | sed -n "${r}p")
			[ -z "$start_line" ] && start_line=1
			next_r=$((r + 1))
			end_line=$(printf '%s\n' "$round_start_lines" | sed -n "${next_r}p")
			if [ -z "$end_line" ]; then
				end_line="$total_lines"
			else
				end_line=$((end_line - 1))
			fi
			accepted=$(sed -n "${start_line},${end_line}p" "$ledger" \
				| jq -rR 'fromjson? // empty' \
				| jq -s '
					([.[] | select(.event=="decision" and .decision=="fix") | .id] | unique) as $fixed
					| ([.[] | select(.event=="intent_verified") | .id] | unique) as $verified
					| [$fixed[] | select(. as $id | $verified | index($id))] | length
				')
			jq --argjson r "$r" --argjson acc "$accepted" \
				'(.[$r-1].accepted) = $acc' "$rounds_json" >"${rounds_json}.tmp" && mv "${rounds_json}.tmp" "$rounds_json"
		done
	fi

	round1_accepted=$(jq '.[0].accepted // 0' "$rounds_json")
	jq --argjson r1 "$round1_accepted" '
		map(. + {
			reflag_rate: (if .findings > 0 then (.reflags / .findings) else 0 end),
			acceptance_rate: (if .findings > 0 then ((.accepted // 0) / .findings) else 0 end),
			marginal_yield: (if $r1 > 0 then ((.accepted // 0) / $r1) else null end)
		})
	' "$rounds_json" >"${rounds_json}.tmp" && mv "${rounds_json}.tmp" "$rounds_json"

	jq --arg repo "$repo_hash" --arg branch_hash "$branch_hash" --arg branch "$branch" --slurpfile rounds "$rounds_json" \
		'. + [{session: {repo_hash: $repo, branch_hash: $branch_hash, branch: $branch}, skipped: false, rounds: $rounds[0]}]' \
		"$sessions_json" >"${sessions_json}.tmp" && mv "${sessions_json}.tmp" "$sessions_json"
done <<<"$session_dirs"

cp "$sessions_json" "${OUT_DIR}/replay-corpus.json"

{
	printf '# replay-corpus\n\n'
	printf '| Session | Round | Findings | Accepted | Re-flag rate | Acceptance rate | Marginal yield | Range escalations |\n'
	printf '|---|---|---|---|---|---|---|---|\n'
	jq -r '
		.[] | select(.skipped | not) as $s
		| $s.rounds[] | [$s.session.branch_hash, .round, .findings, (.accepted // 0),
			(.reflag_rate * 100 | floor | tostring) + "%",
			(.acceptance_rate * 100 | floor | tostring) + "%",
			(if .marginal_yield == null then "n/a" else (.marginal_yield * 100 | floor | tostring) + "%" end),
			.range_escalations] | @tsv
	' "$sessions_json" | awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$8}'
	printf '\n## Contradiction candidates (needs human/model review)\n\n'
	printf 'Same-file, overlapping-range re-flag pairs. Whether the later round'"'"'s remedy\n'
	printf 'actually reverses the earlier one'"'"'s direction is a judgment call this script does\n'
	printf 'not make; never counted into reflag_count or any other rate above.\n\n'
	cand_total=$(jq '[.[] | select(.skipped | not) | .rounds[]?.contradiction_candidates[]?] | length' "$sessions_json")
	if [ "$cand_total" -eq 0 ]; then
		printf 'None.\n'
	else
		jq -r '
			.[] | select(.skipped | not) as $s
			| $s.rounds[] as $r
			| $r.contradiction_candidates[]?
			| "- `\($s.session.branch_hash)` round \($r.round): `\(.current.fileName):\(.current.startLine)` \"\(.current.title)\" vs. prior `\(.prior.fileName):\(.prior.startLine)` \"\(.prior.title)\""
		' "$sessions_json"
	fi

	printf '\n## Skipped sessions\n\n'
	skipped_count=$(jq '[.[] | select(.skipped)] | length' "$sessions_json")
	if [ "$skipped_count" -eq 0 ]; then
		printf 'None.\n'
	else
		jq -r '.[] | select(.skipped) | "- `\(.session.repo_hash)/\(.session.branch_hash)` (\(.session.branch)): \(.skip_reason)"' "$sessions_json"
	fi
} >"${OUT_DIR}/replay-corpus.md"

printf 'Wrote %s and %s\n' "${OUT_DIR}/replay-corpus.json" "${OUT_DIR}/replay-corpus.md"
cat "${OUT_DIR}/replay-corpus.md"
