#!/usr/bin/env bash
# reply-cr.sh: post a guarded, evidence-grounded reply to a CodeRabbit inline
# review-comment thread (Phase 3). Every guard below runs BEFORE any gh
# reference, so a forbidden case never constructs the API call.
#
# Usage: reply-cr.sh <repo> <pr_number> <thread_root_comment_id> <body_file> \
#                     <thread_state_file> <acting_login> [--dry-run]
#
# <thread_state_file> is fetch-cr-threads.sh's output array (Phase 2); this
# script looks up <thread_root_comment_id> in it by comment_id and reads that
# entry's source/is_resolved/reply_logins. <acting_login> is resolved ONCE by
# the caller (gh api user --jq .login) and passed in -- this script does no
# login resolution itself, so it stays a pure function of its inputs.
#
# No ledger of replies beyond reply_logins itself: "already replied to this
# thread" (Guard 4) is derived from reply_logins, which fetch-cr-threads.sh
# populates from live GitHub thread state, not from anything this script
# writes -- plus one addition of our own: fetch-cr-threads.sh deliberately
# EXCLUDES the bot's own login from reply_logins (see its header), so Guard 4
# separately rejects when acting_login IS the bot's login, covering the case
# where this script is invoked with the bot's own credentials.
#
# That snapshot is a single Phase-2 fetch, though, so it goes stale two ways:
#   - a POST attempt for a thread times out or errors AFTER GitHub already
#     created the reply -- indistinguishable here from a genuine failure
#     (reply-cr:post-failed). Guard 8 below guards against a retry on that
#     same stale snapshot double-posting: a small per-thread "a POST was
#     attempted" marker, written just before the POST and never cleared
#     automatically, so a retry with the same thread_state_file refuses
#     instead of reposting blind.
#   - a thread can be resolved, or replied to, by an EXTERNAL actor (a human
#     on GitHub) in the window between the Phase-2 fetch and this script's
#     POST. Guard 8 cannot see that (it only guards this script retrying
#     itself), so Guard 7 below re-checks this one thread's live is_resolved
#     state immediately before the POST.
#
# --dry-run: print the body that would be posted, make zero gh calls, exit 0.
#
# Set PRAF_GH to override the gh entrypoint for offline smoke testing.
#
# Exit codes:
#   0   reply posted (or --dry-run printed successfully)
#   1   usage error, or thread id not found
#   2   gh api POST failed, the live pre-POST resolution recheck (Guard 7)
#       could not be completed, an ambiguous prior attempt marker already
#       exists for this thread+login (Guard 8), or the marker directory is
#       unwritable
#   10  intentional no-op: source is not "inline"; thread already resolved
#       (per the Phase-2 snapshot, or per the live recheck immediately before
#       the POST); acting_login already appears in reply_logins for this
#       thread or is the bot's own login (self-reply); or the body has no
#       evidence citation
set -euo pipefail

usage() {
	printf 'Usage: reply-cr.sh <repo> <pr_number> <thread_root_comment_id> <body_file> <thread_state_file> <acting_login> [--dry-run]\n' >&2
}

if [ $# -lt 6 ] || [ $# -gt 7 ] || { [ $# -eq 7 ] && [ "$7" != "--dry-run" ]; }; then
	usage
	exit 1
fi

REPO="$1"
PR_NUM="$2"
THREAD_ID="$3"
BODY_FILE="$4"
THREAD_STATE_FILE="$5"
ACTING_LOGIN="$6"
DRY_RUN=0
if [ $# -eq 7 ]; then
	DRY_RUN=1
fi
GH="${PRAF_GH:-gh}"

command -v jq >/dev/null 2>&1 || {
	printf 'reply-cr:jq-missing\n' >&2
	exit 2
}
if [ ! -f "$BODY_FILE" ]; then
	printf 'reply-cr:body-file-missing\n' >&2
	exit 1
fi
if [ ! -f "$THREAD_STATE_FILE" ]; then
	printf 'reply-cr:thread-state-file-missing\n' >&2
	exit 1
fi
if ! [[ "$THREAD_ID" =~ ^[0-9]+$ ]]; then
	printf 'reply-cr:bad-thread-id\n' >&2
	exit 1
fi

# --- Guard 1: thread must exist in the fetched state ---
THREAD_JSON=$(jq -c --argjson id "$THREAD_ID" '[.[] | select(.comment_id == $id)] | first // empty' "$THREAD_STATE_FILE")
if [ -z "$THREAD_JSON" ]; then
	printf 'reply-cr:thread-not-found\n' >&2
	exit 1
fi

SOURCE=$(jq -r '.source' <<<"$THREAD_JSON")
IS_RESOLVED=$(jq -r '.is_resolved' <<<"$THREAD_JSON")

# --- Guard 2: never reply to pr-summary or review-body entries -- no thread to reply into ---
if [ "$SOURCE" != "inline" ]; then
	printf 'reply-cr:non-inline-source\n' >&2
	exit 10
fi

# --- Guard 3: never reply to a resolved thread, per the Phase-2 snapshot --
# Guard 7 below re-checks this live, immediately before the POST, since this
# snapshot can go stale between the Phase-2 fetch and the POST (Finding 1) ---
if [ "$IS_RESOLVED" = "true" ]; then
	printf 'reply-cr:thread-resolved\n' >&2
	exit 10
fi

# --- Guard 4: at most one reply per thread, per the Phase-2 snapshot -- Guard 8
# below adds an attempt marker so a retry on this same stale snapshot can't
# double-post after an ambiguous prior failure. Also rejects acting_login ==
# the bot's own login: fetch-cr-threads.sh deliberately excludes the bot from
# reply_logins (every inline entry's root comment is bot-authored by
# construction), so a shared-token scenario where this script acts as the bot
# would otherwise never trip the reply_logins check below (Finding 2) ---
BOT_LOGIN_REGEX='^coderabbitai(\[bot\])?$'
ALREADY_REPLIED=$(jq -r --arg login "$ACTING_LOGIN" '.reply_logins | index($login) != null' <<<"$THREAD_JSON")
if [ "$ALREADY_REPLIED" = "true" ] || [[ "$ACTING_LOGIN" =~ $BOT_LOGIN_REGEX ]]; then
	printf 'reply-cr:already-replied\n' >&2
	exit 10
fi

# --- Guard 5: every reply must cite its evidence -- a real file:line, not a
# bare "word:number" (version:2, 12:30, host:8080, and the bare word
# "evidence:" itself all satisfied the old regex without citing anything
# real); validates against THREAD_PATH from THREAD_JSON so any repository
# file path is accepted, not a fixed extension list (Finding 4). Intentional
# no-op, not a usage error, so this exits 10 like the other deliberate-skip
# guards (Finding 3) ---
BODY_CONTENT=$(cat "$BODY_FILE")
THREAD_PATH=$(jq -r '.path // empty' <<<"$THREAD_JSON")
ESCAPED_PATH=$(printf '%s' "$THREAD_PATH" | sed 's/[]^$.*+?(){}|[]/\\&/g')
if [ -z "$THREAD_PATH" ] || ! [[ "$BODY_CONTENT" =~ ${ESCAPED_PATH}:[0-9]+ ]]; then
	printf 'reply-cr:no-evidence-citation\n' >&2
	exit 10
fi

# --- Guard 6: dry-run prints and stops before any gh reference ---
if [ "$DRY_RUN" -eq 1 ]; then
	printf '%s\n' "$BODY_CONTENT"
	exit 0
fi

# --- Guard 7: re-fetch THIS thread's live is_resolved state immediately
# before the POST, closing the window between Phase 2's snapshot fetch and
# this POST during which an external actor (a human on GitHub) may have
# resolved the thread -- Guard 3 above cannot see that, since it only reads
# the Phase-2 snapshot (Finding 1). A single targeted GraphQL check for just
# this thread_id, not a full re-run of fetch-cr-threads.sh's four-endpoint
# fetch: same reviewThreads query shape, but only the fields this check
# needs. Runs before Guard 8's marker write below, so a thread found already
# resolved here never gets marked as "a POST was attempted". ---
OWNER="${REPO%/*}"
NAME="${REPO#*/}"
# shellcheck disable=SC2016  # GraphQL variables, not shell
RECHECK_QUERY='query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          comments(first: 100) { nodes { databaseId } }
        }
      }
    }
  }
}'
LIVE_IS_RESOLVED=$(
	"$GH" api graphql --paginate \
		-f query="$RECHECK_QUERY" \
		-F owner="$OWNER" -F name="$NAME" -F pr="$PR_NUM" 2>/dev/null \
		| jq -s -r --argjson id "$THREAD_ID" \
			'[.[] | .data.repository.pullRequest.reviewThreads.nodes[]
			| select(any(.comments.nodes[]; .databaseId == $id))
			| .isResolved] | first // empty'
) || {
	printf 'reply-cr:resolution-recheck-failed\n' >&2
	exit 2
}
if [ "$LIVE_IS_RESOLVED" = "true" ]; then
	printf 'reply-cr:thread-resolved\n' >&2
	exit 10
fi

# --- Guard 8: refuse a retry after an ambiguous prior attempt -- a POST that
# times out or errors AFTER GitHub already created the reply is indistinguishable
# from a genuine failure (reply-cr:post-failed below); a marker recording "a POST
# was attempted for this thread+login" is created just BEFORE the POST and never
# cleared automatically, mirroring run-af-review.sh's execution.json (written
# before the risky call so a later invocation can't blindly resubmit). Colocated
# next to thread_state_file so no new state-directory configuration is needed.
# The marker itself is a directory, created via `mkdir` so the check-and-create
# is a single atomic operation -- two concurrent invocations can't both observe
# no marker and both proceed to POST. ---
MARKER_DIR="$(dirname "$THREAD_STATE_FILE")/.reply-attempts"
if ! mkdir -p "$MARKER_DIR" 2>/dev/null; then
	printf 'reply-cr:marker-dir-unwritable -- cannot create %s\n' "$MARKER_DIR" >&2
	exit 2
fi
MARKER_FILE="${MARKER_DIR}/${REPO//\//_}__${PR_NUM}__${THREAD_ID}__${ACTING_LOGIN}"
if ! mkdir "$MARKER_FILE" 2>/dev/null; then
	printf 'reply-cr:prior-attempt-ambiguous -- a previous POST for this thread/login did not confirm success or failure (marker: %s); verify on GitHub before retrying\n' "$MARKER_FILE" >&2
	exit 2
fi

# --- Post ---
if ! "$GH" api "repos/${REPO}/pulls/${PR_NUM}/comments/${THREAD_ID}/replies" \
	--method POST -f body="$BODY_CONTENT" >/dev/null 2>&1; then
	printf 'reply-cr:post-failed\n' >&2
	exit 2
fi

exit 0
