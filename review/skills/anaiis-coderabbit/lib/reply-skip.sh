#!/usr/bin/env bash
# reply-skip.sh: post a terse explanatory reply on a skipped CodeRabbit PR
# review-comment thread (PR mode only). Triggers the CodeRabbit bot to
# respond, giving skipped findings an auditable trail instead of a silently
# unresolved thread.
#
# Usage: reply-skip.sh <repo> <pr_number> <finding_id> <source> <severity> <rationale>
#
# <source> must be "pr-inline" for a reply to be posted -- a "pr-summary"
# finding has no real comment thread to reply into (see parse-pr-comments.py),
# so this is an intentional no-op, not an error.
#
# Set REPLY_SKIP_GH to override the gh entrypoint for offline smoke testing
# (mirrors review-round.sh's REVIEW_CMD and intent-preflight.sh's
# INTENT_PREFLIGHT_DIFF injection seams).
#
# Exit codes:
#   0   reply posted
#   10  intentional no-op (source is not pr-inline; no thread to reply into)
#   1   usage error or malformed finding id
#   2   gh api POST failed

set -euo pipefail

if [[ $# -lt 6 ]]; then
	printf 'Usage: reply-skip.sh <repo> <pr_number> <finding_id> <source> <severity> <rationale>\n' >&2
	exit 1
fi

REPO="$1"
PR_NUM="$2"
FINDING_ID="$3"
SOURCE="$4"
SEVERITY="$5"
RATIONALE="$6"
GH="${REPLY_SKIP_GH:-gh}"

if [[ "$SOURCE" != "pr-inline" ]]; then
	printf 'reply-skip:non-inline-source\n' >&2
	exit 10
fi

COMMENT_ID="${FINDING_ID#PR-"${PR_NUM}"-}"
if [[ "$COMMENT_ID" == "$FINDING_ID" ]] || [[ -z "$COMMENT_ID" ]] || ! [[ "$COMMENT_ID" =~ ^[0-9]+$ ]]; then
	printf 'reply-skip:bad-id\n' >&2
	exit 1
fi

BODY=$(
	cat <<EOF
**anaiis-coderabbit triage: skipped (severity ${SEVERITY}).**

${RATIONALE}

Reply here if this should be reconsidered; it will be re-triaged on the next \`/anaiis-coderabbit --pr\` run.
EOF
)

if ! "$GH" api "repos/${REPO}/pulls/${PR_NUM}/comments/${COMMENT_ID}/replies" \
	--method POST -f body="$BODY" >/dev/null 2>&1; then
	printf 'reply-skip:post-failed\n' >&2
	exit 2
fi

exit 0
