#!/usr/bin/env bash
# fetch-cr-threads.sh: fetch every CodeRabbit comment surface for a PR (Phase 2 read step).
#
# Merges FOUR sources GitHub splits across separate endpoints into one thread-centric
# JSON array on stdout:
#   1. REST inline review comments    (source: "inline")      -- file/line, threaded
#   2. REST issue/PR-summary comments (source: "pr-summary")  -- no file/line, unthreaded
#   3. REST review bodies             (source: "review-body") -- no file/line, unthreaded;
#      the gap rabbit-sweep's fetch-pr-findings.sh never closes: a CodeRabbit finding can
#      exist ONLY in a review body when inline posting failed.
#   4. GraphQL reviewThreads (isResolved/isOutdated/reply author logins) -- REST alone
#      cannot expose thread resolution; joined onto (1) by comment id.
#
# Usage: fetch-cr-threads.sh <owner/repo> <pr_number>
# Prints one JSON array to stdout, elements:
#   {comment_id, thread_id, source, path, line, body, is_resolved, is_outdated, reply_logins}
# thread_id is the root comment id for "inline" (a comment's own id if it started the
# thread, else its in_reply_to_id); null for "pr-summary"/"review-body" -- GitHub has no
# thread concept there. is_resolved/is_outdated are null and reply_logins is [] outside
# "inline" -- GraphQL review-thread state only covers inline review-comment threads.
# reply_logins excludes the bot itself; T6's reply guard filters it for the acting login
# (no local ledger -- GitHub's own thread state is the source of truth).
#
# Read-only. Set PRAF_GH to override the gh entrypoint for offline smoke testing.
#
# Exit codes:
#   0  ok (array may be empty)
#   1  usage error
#   2  gh/jq missing, or an API call failed
set -euo pipefail

GH="${PRAF_GH:-gh}"
BOT_REGEX='^coderabbitai(\[bot\])?$'

usage() {
	printf 'Usage: fetch-cr-threads.sh <owner/repo> <pr_number>\n' >&2
}

if [ $# -lt 2 ]; then
	usage
	exit 1
fi

REPO="$1"
PR="$2"

if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
	printf '[fetch-cr-threads] repo must be <owner>/<name>, got: %s\n' "$REPO" >&2
	exit 1
fi
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
	printf '[fetch-cr-threads] PR number must be numeric, got: %s\n' "$PR" >&2
	exit 1
fi

command -v "$GH" >/dev/null 2>&1 || {
	printf '[fetch-cr-threads] %s not found. Install via: brew install gh\n' "$GH" >&2
	exit 2
}
command -v jq >/dev/null 2>&1 || {
	printf '[fetch-cr-threads] jq not found. Install via: brew install jq\n' >&2
	exit 2
}

OWNER="${REPO%/*}"
NAME="${REPO#*/}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- 1. inline review comments (threaded, file/line) ---
if ! "$GH" api "repos/${REPO}/pulls/${PR}/comments" --paginate >"${TMP}/inline-raw.json" 2>/dev/null; then
	printf 'fetch-cr-threads:inline-fetch-failed\n' >&2
	exit 2
fi
jq -s --arg re "$BOT_REGEX" '
	[.[][]
	| select((.user.login // "") | test($re))
	| {
		comment_id: .id,
		thread_id: (.in_reply_to_id // .id),
		source: "inline",
		path: .path,
		line: (.line // .original_line),
		body: .body
	}]
' "${TMP}/inline-raw.json" >"${TMP}/inline.json"

# --- 2. issue/PR-summary comments (unthreaded) ---
if ! "$GH" api "repos/${REPO}/issues/${PR}/comments" --paginate >"${TMP}/summary-raw.json" 2>/dev/null; then
	printf 'fetch-cr-threads:summary-fetch-failed\n' >&2
	exit 2
fi
jq -s --arg re "$BOT_REGEX" '
	[.[][]
	| select((.user.login // "") | test($re))
	| {comment_id: .id, thread_id: null, source: "pr-summary", path: null, line: null, body: .body}]
' "${TMP}/summary-raw.json" >"${TMP}/summary.json"

# --- 3. review bodies (unthreaded; the gap rabbit-sweep never closes) ---
if ! "$GH" api "repos/${REPO}/pulls/${PR}/reviews" --paginate >"${TMP}/reviews-raw.json" 2>/dev/null; then
	printf 'fetch-cr-threads:reviews-fetch-failed\n' >&2
	exit 2
fi
jq -s --arg re "$BOT_REGEX" '
	[.[][]
	| select((.user.login // "") | test($re))
	| select((.body // "") != "")
	| {comment_id: .id, thread_id: null, source: "review-body", path: null, line: null, body: .body}]
' "${TMP}/reviews-raw.json" >"${TMP}/reviews.json"

# --- 4. GraphQL thread state (inline threads only), one row per comment id ---
# This query/paginate/jq-s shape is intentionally similar to rabbit-sweep's
# fetch-thread-state.sh (same reviewThreads query, same bot-filter predicate).
# Cross-skill consolidation into a shared lib/ is a known, tracked follow-up,
# not implemented here (out of scope: this file only).
#
# NOTE: --paginate only follows the top-level reviewThreads cursor; the nested
# comments(first: 100) connection below is NOT paginated by it. A thread with
# >100 comments is truncated here, so reply_logins/comment rows past the
# 100th comment go silently missing. totalCount is fetched alongside the
# capped nodes list so truncation is detected and surfaced as a loud stderr
# warning (see the jq pass right after the fetch) instead of silently wrong.
# shellcheck disable=SC2016  # GraphQL variables, not shell
QUERY='query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          comments(first: 100) {
            totalCount
            nodes { databaseId author { login } }
          }
        }
      }
    }
  }
}'

if ! "$GH" api graphql --paginate \
	-f query="$QUERY" \
	-F owner="$OWNER" -F name="$NAME" -F pr="$PR" >"${TMP}/threads-raw.json" 2>/dev/null; then
	printf 'fetch-cr-threads:thread-state-fetch-failed\n' >&2
	exit 2
fi
# --paginate emits one response document per page; jq -s collects them.
# GraphQL strips the [bot] suffix from bot logins, but $re matches both forms.

# Loud warning (never silent) for any bot thread whose comment count exceeds
# the 100-node cap above: reply_logins/comment rows for that thread are
# incomplete past the 100th comment.
jq -s -r --arg re "$BOT_REGEX" '
	.[] | .data.repository.pullRequest.reviewThreads.nodes[]
	| select(any(.comments.nodes[]; (.author.login? // "") | test($re)))
	| . as $t
	| ($t.comments.nodes | length) as $fetched
	| $t.comments.totalCount as $total
	| select($total > $fetched)
	| "praf:thread-comments-truncated -- thread \($t.comments.nodes[0].databaseId // "unknown") has \($total) comments, only \($fetched) fetched, reply_logins may be incomplete"
' "${TMP}/threads-raw.json" >&2

jq -s --arg re "$BOT_REGEX" '
	[.[] | .data.repository.pullRequest.reviewThreads.nodes[]
	| select(any(.comments.nodes[]; (.author.login? // "") | test($re)))
	| . as $t
	| ($t.comments.nodes
		| map(select((.author.login? // "") | test($re) | not) | .author.login)
		| unique) as $replies
	| $t.comments.nodes[]
	| select(.databaseId != null)
	| {comment_id: .databaseId, is_resolved: $t.isResolved, is_outdated: $t.isOutdated, reply_logins: $replies}
	]
' "${TMP}/threads-raw.json" >"${TMP}/threads.json"

# --- merge: attach thread state to inline entries by comment_id lookup ---
jq -s '
	(.[3] | INDEX(.comment_id)) as $tstate
	| (.[0] | map(. + ($tstate[(.comment_id | tostring)] // {is_resolved: null, is_outdated: null, reply_logins: []}))) as $inline
	| (.[1] | map(. + {is_resolved: null, is_outdated: null, reply_logins: []})) as $summary
	| (.[2] | map(. + {is_resolved: null, is_outdated: null, reply_logins: []})) as $reviews
	| $inline + $summary + $reviews
' "${TMP}/inline.json" "${TMP}/summary.json" "${TMP}/reviews.json" "${TMP}/threads.json"
