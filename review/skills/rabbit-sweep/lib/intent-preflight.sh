#!/usr/bin/env bash
# intent-preflight.sh: deterministic pre-verifier checks for rabbit-sweep.
# Usage: intent-preflight.sh <file> <line_start> <line_end>
# Exits 0 if all checks pass; exits 1 with reason on stderr (preflight:<code>).
#
# For smoke testing, set INTENT_PREFLIGHT_DIFF=<path> to read diff content from
# a fixture file instead of running git. Production use leaves this unset.
#
# Set INTENT_PREFLIGHT_SUGGESTED_FIX=<text> to the finding's suggested_fix
# content. If it is itself comment-only, a comment-only diff no longer fails
# check 3 -- the finding was about a comment being wrong, so fixing only the
# comment is the correct outcome, not evidence the surgeon skipped the fix.

set -euo pipefail

if [[ $# -lt 3 ]]; then
	printf 'Usage: intent-preflight.sh <file> <line_start> <line_end>\n' >&2
	exit 1
fi

FILE="$1"
LINE_START="$2"
LINE_END="$3"
WINDOW=20

# Reject non-numeric/empty/null line args explicitly, before they reach
# arithmetic. Bash's set -u treats a non-numeric string like "abc" or "null"
# as an unbound-variable reference inside $((...)), crashing loudly; but an
# empty string evaluates silently to 0, which would pass preflight range
# checks against the wrong line entirely instead of failing at all. Both
# failure modes are worse than a clear, distinguishable rejection here.
if ! [[ "$LINE_START" =~ ^[0-9]+$ ]] || ! [[ "$LINE_END" =~ ^[0-9]+$ ]]; then
	printf 'preflight:bad-line-args\n' >&2
	exit 1
fi

if [[ -n "${INTENT_PREFLIGHT_DIFF:-}" ]]; then
	diff_content=$(cat "$INTENT_PREFLIGHT_DIFF")
else
	diff_content=$(git diff HEAD -- "$FILE" 2>/dev/null)
fi

# Check 1: diff is non-empty for the named file.
if [[ -z "$diff_content" ]]; then
	printf 'preflight:wrong-file\n' >&2
	exit 1
fi

# Check 2: at least one hunk overlaps the finding's line range (+-WINDOW lines).
range_start=$((LINE_START - WINDOW))
range_end=$((LINE_END + WINDOW))
[[ $range_start -lt 1 ]] && range_start=1

overlaps=0
while IFS= read -r line; do
	# Match unified diff hunk header: @@ -old_start,old_count +new_start,new_count @@
	if [[ "$line" =~ ^@@\ -[0-9]+,?[0-9]*\ \+([0-9]+),?([0-9]*)\ @@ ]]; then
		hunk_start="${BASH_REMATCH[1]}"
		hunk_count="${BASH_REMATCH[2]}"
		[[ -z "$hunk_count" ]] && hunk_count=1
		hunk_end=$((hunk_start + hunk_count))
		if ((hunk_start <= range_end && hunk_end >= range_start)); then
			overlaps=1
			break
		fi
	fi
done <<<"$diff_content"

if [[ "$overlaps" -eq 0 ]]; then
	printf 'preflight:line-range\n' >&2
	exit 1
fi

# Check 3: at least one changed line is not a comment or blank -- unless the
# finding's own suggested_fix is itself comment-only (see header).
# Comment markers: # (R/Python/Shell), // (JS/TS/C++), -- (SQL), /* or * (C-style block).
is_comment_or_blank() {
	[[ "$1" =~ ^[[:space:]]*(#|//|--|\/\*|\*)[[:space:]] ]] || [[ "$1" =~ ^[[:space:]]*$ ]]
}

suggested_fix_is_comment_only=0
if [[ -n "${INTENT_PREFLIGHT_SUGGESTED_FIX:-}" ]]; then
	suggested_fix_all_comments=1
	suggested_fix_has_content=0
	while IFS= read -r sline; do
		if ! is_comment_or_blank "$sline"; then
			suggested_fix_all_comments=0
			break
		fi
		[[ -n "${sline// /}" ]] && suggested_fix_has_content=1
	done <<<"$INTENT_PREFLIGHT_SUGGESTED_FIX"
	if [[ "$suggested_fix_all_comments" -eq 1 && "$suggested_fix_has_content" -eq 1 ]]; then
		suggested_fix_is_comment_only=1
	fi
fi

has_real_change=0
while IFS= read -r line; do
	# Only inspect added/removed lines, not context or file-header lines.
	if [[ "$line" =~ ^[+-] ]] && ! [[ "$line" =~ ^(---|\+\+\+) ]]; then
		content="${line:1}"
		if ! is_comment_or_blank "$content"; then
			has_real_change=1
			break
		fi
	fi
done <<<"$diff_content"

if [[ "$has_real_change" -eq 0 ]] && [[ "$suggested_fix_is_comment_only" -eq 0 ]]; then
	printf 'preflight:comment-only\n' >&2
	exit 1
fi

exit 0
