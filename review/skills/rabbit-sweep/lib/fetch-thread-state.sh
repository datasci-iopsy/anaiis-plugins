#!/usr/bin/env bash
# fetch-thread-state.sh: fetch CodeRabbit review-thread resolution state for a PR.
#
# GitHub's REST API does not expose thread resolution; isResolved/isOutdated
# exist only on the GraphQL reviewThreads connection, so this is the one
# GraphQL call in the skill. Phase 3' (pr-mode.md) uses the output as a second
# idempotency filter: findings whose thread a human already resolved (or that
# went outdated under newer commits) are dropped before triage.
#
# Usage: fetch-thread-state.sh <owner/repo> <pr_number> <out_file>
#
# Writes <out_file> as a JSON array covering every comment in every review
# thread that contains at least one coderabbitai comment:
#   [{"comment_id": <databaseId>, "is_resolved": <bool>, "is_outdated": <bool>}, ...]
# All comment IDs in a thread are mapped (not just the root) so replies
# resolve with their thread.
#
# Set THREAD_STATE_GH to override the gh entrypoint for offline smoke testing
# (mirrors REPLY_SKIP_GH and REVIEW_CMD injection seams).
#
# Exit codes:
#   0  ok (out_file written, possibly an empty array)
#   1  usage error
#   2  gh/auth/API failure (caller fails open with a warning)

set -euo pipefail

if [[ $# -lt 3 ]]; then
	printf 'Usage: fetch-thread-state.sh <owner/repo> <pr_number> <out_file>\n' >&2
	exit 1
fi

REPO="$1"
PR_NUM="$2"
OUT_FILE="$3"
GH="${THREAD_STATE_GH:-gh}"

if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
	printf '[fetch-thread-state] repo must be <owner>/<name>, got: %s\n' "$REPO" >&2
	exit 1
fi
OWNER="${REPO%/*}"
NAME="${REPO#*/}"

if ! [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
	printf '[fetch-thread-state] PR number must be numeric, got: %s\n' "$PR_NUM" >&2
	exit 1
fi

command -v jq >/dev/null 2>&1 || {
	printf '[fetch-thread-state] jq not found. Install via: brew install jq\n' >&2
	exit 1
}

# shellcheck disable=SC2016  # $owner/$name/$pr/$endCursor are GraphQL variables, not shell
QUERY='query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          comments(first: 100) {
            nodes { databaseId author { login } }
          }
        }
      }
    }
  }
}'

RESPONSE=""
if ! RESPONSE=$("$GH" api graphql --paginate \
	-f query="$QUERY" \
	-F owner="$OWNER" -F name="$NAME" -F pr="$PR_NUM" 2>/dev/null); then
	printf 'thread-state:fetch-failed\n' >&2
	exit 2
fi

# --paginate emits one response document per page; jq -s collects them.
# GraphQL strips the [bot] suffix from bot logins, but match both forms.
if ! printf '%s' "$RESPONSE" | jq -s '
	[ .[]
	  | .data.repository.pullRequest.reviewThreads.nodes[]
	  | select(any(.comments.nodes[]; (.author.login? // "") | test("^coderabbitai(\\[bot\\])?$")))
	  | . as $t
	  | $t.comments.nodes[]
	  | select(.databaseId != null)
	  | {comment_id: .databaseId, is_resolved: $t.isResolved, is_outdated: $t.isOutdated}
	]' >"$OUT_FILE"; then
	printf 'thread-state:fetch-failed\n' >&2
	exit 2
fi

count=$(jq 'length' "$OUT_FILE")
printf '[fetch-thread-state] %s comment(s) mapped across CodeRabbit threads for PR #%s\n' "$count" "$PR_NUM" >&2
