#!/usr/bin/env bash
# Preflight checks for the pr-af skill (Phase 0): af binary, control plane, pr-af node,
# PR resolvability, CodeRabbit readiness, and run-key computation.
# Usage: preflight.sh --pr <number|url>
# On success (exit 0) emits one JSON object on stdout:
#   {pr, url, head_sha, is_draft, cr_ready, run_key, archive_exists}
# `cr_ready: false` is advisory, not fatal -- printed as praf:cr-not-ready to stderr.
#
# Exit codes:
#   0  success (cr_ready may still be false)
#   1  usage error
#   2  praf:af-missing        -- $PRAF_AF_BIN not found
#   3  praf:plane-unreachable -- control plane not reachable
#   4  praf:node-missing      -- pr-af node not registered/live on the plane
#   5  praf:gh-unavailable    -- gh/jq missing or gh not authenticated
#   6  praf:pr-not-found      -- PR arg unresolvable via gh
#   7  praf:pr-not-open       -- PR is closed or merged
set -euo pipefail

AF="${PRAF_AF_BIN:-af}"
GH="${PRAF_GH:-gh}"
RUNS_DIR="${PRAF_RUNS_DIR:-$HOME/.pr-af/runs}"
MODEL="${PRAF_MODEL:-deepseek/deepseek-v4-flash-0731}"

usage() {
	printf 'Usage: preflight.sh --pr <number|url>\n' >&2
}

PR_ARG=""
while [ $# -gt 0 ]; do
	case "$1" in
		--pr)
			PR_ARG="${2:-}"
			shift 2
			;;
		--pr=*)
			PR_ARG="${1#--pr=}"
			shift
			;;
		*)
			usage
			exit 1
			;;
	esac
done

if [ -z "$PR_ARG" ]; then
	usage
	exit 1
fi

command -v "$AF" >/dev/null 2>&1 || {
	printf 'praf:af-missing -- %s not found. Install AgentField: curl -fsSL https://agentfield.ai/install.sh | bash\n' "$AF" >&2
	exit 2
}

command -v "$GH" >/dev/null 2>&1 || {
	printf 'praf:gh-unavailable -- %s not found. Install via: brew install gh\n' "$GH" >&2
	exit 5
}

command -v jq >/dev/null 2>&1 || {
	printf 'praf:gh-unavailable -- jq not found. Install via: brew install jq\n' >&2
	exit 5
}

"$GH" auth status >/dev/null 2>&1 || {
	printf 'praf:gh-unavailable -- not authenticated. Run: gh auth login\n' >&2
	exit 5
}

# --- control plane + pr-af node: af ls's own exit code disambiguates plane-down
# (connection error, non-zero exit) from plane-up-but-no-matching-reasoner (exit 0). ---
AF_LS_EXIT=0
AF_LS_OUT=$("$AF" ls -o json 2>&1) || AF_LS_EXIT=$?
if [ "$AF_LS_EXIT" -ne 0 ]; then
	printf 'praf:plane-unreachable -- control plane not reachable. Start it with: af server (or launch the AgentField desktop app)\n' >&2
	exit 3
fi

# NOTE: the `af ls -o json` schema for a populated result is confirmed against a live
# AgentField 0.1.137 instance with a registered pr-af node:
#   {reasoners:[{node,reasoner,tags,last_run_at,status}], shown, total}
# The jq matcher below (via the .reasoners/.node path) correctly identifies the node
# against that real schema; the other shapes stay as a defensive fallback.
NODE_FOUND=$(
	jq -r '
        [(.data // .reasoners // .) // []]
        | flatten
        | map(select(
            ((.node? // .name? // "") | tostring) == "pr-af"
            or ((.node? // .name? // "") | tostring | startswith("pr-af"))
        ))
        | length > 0
    ' <<<"$AF_LS_OUT" 2>/dev/null || echo false
)

if [ "$NODE_FOUND" != "true" ]; then
	printf 'praf:node-missing -- pr-af node not registered on the plane. Install and run it:\n  af install https://github.com/Agent-Field/pr-af\n  af run pr-af\n' >&2
	exit 4
fi

# --- resolve PR: a bare number (current repo via gh) or a full github.com PR URL ---
if [[ "$PR_ARG" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
	REPO="${BASH_REMATCH[1]}"
	PR="${BASH_REMATCH[2]}"
elif [[ "$PR_ARG" =~ ^[0-9]+$ ]]; then
	PR="$PR_ARG"
	REPO=$("$GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
		printf 'praf:pr-not-found -- could not resolve current repo via gh; pass a full PR URL instead\n' >&2
		exit 6
	}
else
	printf 'praf:pr-not-found -- --pr must be a number or a github.com PR URL, got: %s\n' "$PR_ARG" >&2
	exit 6
fi

PR_JSON=$("$GH" pr view "$PR" --repo "$REPO" --json number,url,headRefOid,state,isDraft 2>/dev/null) || {
	printf 'praf:pr-not-found -- PR #%s not found in %s\n' "$PR" "$REPO" >&2
	exit 6
}

STATE=$(jq -r '.state' <<<"$PR_JSON")
if [ "$STATE" != "OPEN" ]; then
	printf 'praf:pr-not-open -- PR #%s state is %s\n' "$PR" "$STATE" >&2
	exit 7
fi

URL=$(jq -r '.url' <<<"$PR_JSON")
HEAD_SHA=$(jq -r '.headRefOid' <<<"$PR_JSON")
IS_DRAFT=$(jq -r '.isDraft' <<<"$PR_JSON")
SHA12="${HEAD_SHA:0:12}"

# --- CodeRabbit readiness (advisory, never fatal) ---
REVIEWS_JSON=$("$GH" api "repos/${REPO}/pulls/${PR}/reviews" --paginate 2>/dev/null) || REVIEWS_JSON="[]"
CR_READY=$(
	jq -r '
        [.[] | select((.user.login // "") | test("^coderabbitai(\\[bot\\])?$")) | select(.state != "PENDING")]
        | length > 0
    ' <<<"$REVIEWS_JSON" 2>/dev/null || echo false
)

if [ "$CR_READY" != "true" ]; then
	printf 'praf:cr-not-ready -- no completed CodeRabbit review found yet on PR #%s (advisory, not fatal)\n' "$PR" >&2
fi

# --- run key + archive check ---
REPO_SLUG="${REPO//\//-}"
MODEL_SLUG="${MODEL//\//_}"
RUN_KEY="${REPO_SLUG}-pr${PR}-${SHA12}-${MODEL_SLUG}"
ARCHIVE_EXISTS=false
RESPONSE_FILE="${RUNS_DIR}/${RUN_KEY}/response.json"
if [ -f "$RESPONSE_FILE" ] && jq -e . "$RESPONSE_FILE" >/dev/null 2>&1; then
	ARCHIVE_EXISTS=true
fi

jq -n \
	--arg pr "$PR" \
	--arg url "$URL" \
	--arg head_sha "$HEAD_SHA" \
	--argjson is_draft "$IS_DRAFT" \
	--argjson cr_ready "$CR_READY" \
	--arg run_key "$RUN_KEY" \
	--argjson archive_exists "$ARCHIVE_EXISTS" \
	'{pr: ($pr | tonumber), url: $url, head_sha: $head_sha, is_draft: $is_draft, cr_ready: $cr_ready, run_key: $run_key, archive_exists: $archive_exists}'
