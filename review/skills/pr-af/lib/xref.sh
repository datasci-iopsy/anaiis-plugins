#!/usr/bin/env bash
# xref.sh: deterministic cross-reference of pr-af findings against CodeRabbit threads
# (Phase 2 join step). Pure jq, no network calls, no gh, no curl, no judgment calls --
# a file+line join only. Reasoning over the result is Phase 3's (the model's) job.
#
# Usage: xref.sh <response.json> <cr_threads.json>
#   response.json    -- verbatim pr-af archive from run-af-review.sh (has .findings[])
#   cr_threads.json  -- array from fetch-cr-threads.sh
#
# Only source=="inline" CR entries carry a file/line, so only they can match a pr-af
# finding; pr-af findings carry a single `line`, and so does an "inline" CR entry (no
# ranges exist in either data model), so the match is exact file+line equality, not an
# interval test. Multiple bot comments can share a thread_id (a root plus its own later
# reply); they are grouped by thread_id before matching, and the root's own body (the
# entry whose comment_id equals the thread_id) is used as cr_summary, falling back to
# the first entry in the group if no comment_id happens to equal the thread_id. Two
# different pr-af findings matching the same thread both land in that thread's
# matched_praf_findings array; a finding matching multiple threads (only possible if
# two distinct CR threads happen to point at the exact same file+line) appears under
# each.
#
# Prints one JSON object to stdout:
#   {matched: [{thread_id, cr_summary, matched_praf_findings}],
#    cr_unmatched: [{thread_id, cr_summary}],
#    praf_unmatched: [...pr-af findings with no matching inline thread...],
#    pr_summary_and_review_body: [...non-inline CR entries, as-is...]}
#
# Exit codes: 0 ok (arrays may be empty), 1 usage error, 2 jq missing, a file is
# missing, or a file failed to parse as JSON.
set -euo pipefail

usage() {
	printf 'Usage: xref.sh <response.json> <cr_threads.json>\n' >&2
}

if [ $# -lt 2 ]; then
	usage
	exit 1
fi

RESPONSE="$1"
CR_THREADS="$2"

command -v jq >/dev/null 2>&1 || {
	printf '[xref] jq not found. Install via: brew install jq\n' >&2
	exit 2
}

for f in "$RESPONSE" "$CR_THREADS"; do
	if [ ! -f "$f" ]; then
		printf '[xref] file not found: %s\n' "$f" >&2
		exit 2
	fi
done

if ! jq -n \
	--slurpfile praf "$RESPONSE" \
	--slurpfile cr "$CR_THREADS" '
	((($praf[0] // {}) | .findings) // []) as $findings
	| ($cr[0] // []) as $cr_all
	| ($cr_all | map(select(.source == "inline"))) as $inline
	| ($cr_all | map(select(.source != "inline"))) as $non_inline

	| ($inline
		| group_by(.thread_id)
		| map({
			thread_id: .[0].thread_id,
			cr_summary: ((map(select(.comment_id == .thread_id)) | .[0].body) // .[0].body)
		})) as $threads
	| ($threads | map({(.thread_id | tostring): .}) | add // {}) as $thread_index

	| ($findings | to_entries | map({idx: .key, finding: .value})) as $findings_idx

	| [ $findings_idx[] as $fi
		| $inline[] as $e
		| select(
			($fi.finding.file_path // null) != null
			and ($fi.finding.line_start // null) != null
			and ($fi.finding.line_end // null) != null
			and ($e.is_outdated // false) != true
			and $e.path == $fi.finding.file_path
			and $e.line >= $fi.finding.line_start
			and $e.line <= $fi.finding.line_end
		)
		| {idx: $fi.idx, finding: $fi.finding, thread_id: $e.thread_id}
	] | unique_by([.idx, .thread_id]) as $pairs

	| ($pairs
		| group_by(.thread_id)
		| map({
			thread_id: .[0].thread_id,
			cr_summary: $thread_index[(.[0].thread_id | tostring)].cr_summary,
			matched_praf_findings: map(.finding)
		})) as $matched

	| ($matched | map(.thread_id)) as $matched_thread_ids
	| ($threads | map(select(([.thread_id] - $matched_thread_ids) != []))) as $cr_unmatched

	| ($pairs | map(.idx) | unique) as $matched_idxs
	| ($findings_idx
		| map(select(([.idx] - $matched_idxs) != []))
		| map(.finding)) as $praf_unmatched

	| {
		matched: $matched,
		cr_unmatched: $cr_unmatched,
		praf_unmatched: $praf_unmatched,
		pr_summary_and_review_body: $non_inline
	}
'; then
	printf '[xref] failed to parse or process input JSON\n' >&2
	exit 2
fi
