#!/usr/bin/env bash
# Thin wrapper for coderabbit review --agent.
# Usage: run-review.sh <base> [--type <all|committed|uncommitted>] [--dir <path>]
# Stdout: raw NDJSON from coderabbit. Exits non-zero on auth failure or review error.

set -euo pipefail

BASE="${1:-}"
if [ -z "$BASE" ]; then
	echo "Usage: run-review.sh <base> [--type <type>] [--dir <path>]" >&2
	exit 1
fi
shift

# Dependency checks
command -v coderabbit >/dev/null 2>&1 || {
	echo "[run-review] coderabbit not found. Install via: brew install --cask coderabbit" >&2
	exit 1
}
command -v jq >/dev/null 2>&1 || {
	echo "[run-review] jq not found. Install via: brew install jq" >&2
	exit 1
}

# Auth check
if ! coderabbit auth status --agent | jq -e '.authenticated == true' >/dev/null 2>&1; then
	echo "[run-review] Not authenticated. Run: coderabbit auth login" >&2
	exit 2
fi

exec coderabbit review --agent --base "$BASE" --no-color "$@"
