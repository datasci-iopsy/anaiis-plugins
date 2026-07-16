#!/usr/bin/env bash
# Fetch CodeRabbit bot comments from a GitHub PR.
# Usage: fetch-pr-findings.sh <owner/repo> <pr_number> <out_dir>
# Writes:
#   <out_dir>/pr-inline.json   -- inline review comments by coderabbitai[bot]
#   <out_dir>/pr-summary.json  -- issue-level comments by coderabbitai[bot]
# Exits non-zero on auth failure, missing args, or API error.

set -euo pipefail

REPO="${1:-}"
PR="${2:-}"
OUT="${3:-}"

if [ -z "$REPO" ] || [ -z "$PR" ] || [ -z "$OUT" ]; then
	echo "Usage: fetch-pr-findings.sh <owner/repo> <pr_number> <out_dir>" >&2
	exit 1
fi

if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
	echo "[fetch-pr-findings] PR number must be numeric, got: ${PR}" >&2
	exit 1
fi

command -v gh >/dev/null 2>&1 || {
	echo "[fetch-pr-findings] gh not found. Install via: brew install gh" >&2
	exit 1
}

command -v jq >/dev/null 2>&1 || {
	echo "[fetch-pr-findings] jq not found. Install via: brew install jq" >&2
	exit 1
}

if ! gh auth status >/dev/null 2>&1; then
	echo "[fetch-pr-findings] Not authenticated. Run: gh auth login" >&2
	exit 2
fi

mkdir -p "$OUT"

# Inline review comments (line-level, on the diff)
gh api \
	"repos/${REPO}/pulls/${PR}/comments" \
	--paginate \
	| jq -s '[.[][] | select(.user.login == "coderabbitai[bot]") | {
        id: .id,
        path: .path,
        line: (.line // .original_line),
        body: .body,
        diff_hunk: .diff_hunk,
        commit_id: .commit_id
    }]' \
		>"${OUT}/pr-inline.json"

# Top-level PR comments (summary, walkthrough, etc.)
gh api \
	"repos/${REPO}/issues/${PR}/comments" \
	--paginate \
	| jq -s '[.[][] | select(.user.login == "coderabbitai[bot]") | {
        id: .id,
        path: null,
        line: null,
        body: .body
    }]' \
		>"${OUT}/pr-summary.json"

inline_count=$(jq 'length' "${OUT}/pr-inline.json")
summary_count=$(jq 'length' "${OUT}/pr-summary.json")
echo "[fetch-pr-findings] Fetched ${inline_count} inline + ${summary_count} summary comments from PR #${PR}"
