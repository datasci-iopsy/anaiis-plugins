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

# Run review and normalize output to the shared finding schema.
# Filters only type=="finding" lines; status/context lines are discarded.
# Actual CLI schema: fileName, codegenInstructions, suggestions[], severity (label).
# Output schema: {id, file, line, severity, title, body, suggested_fix, source}
coderabbit review --agent --base "$BASE" "$@" \
	| jq -c 'select(.type == "finding")' \
	| jq -sc 'to_entries[] | .value + {_idx: (.key + 1)}' \
	| jq -c '
    {
        id: ("CLI-" + (._idx | tostring)),
        file: .fileName,
        line: null,
        severity: (
            if   .severity == "critical" then 5
            elif .severity == "major"    then 4
            elif .severity == "minor"    then 3
            elif .severity == "nitpick"  then 2
            else 3 end
        ),
        title: (
            .codegenInstructions
            | split("\n\n")
            | map(select(startswith("Verify") | not))
            | first // ""
            | split("\n") | first | .[0:120]
        ),
        body: .codegenInstructions,
        suggested_fix: (if (.suggestions | length) > 0 then .suggestions[0] else null end),
        source: "cli"
    }
'
