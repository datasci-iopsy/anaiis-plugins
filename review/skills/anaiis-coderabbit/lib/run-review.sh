#!/usr/bin/env bash
# Thin wrapper for coderabbit review --agent.
# Usage: run-review.sh <base> [--type <all|committed|uncommitted>] [--dir <path>]
# Stdout: normalized NDJSON findings from coderabbit. Exits non-zero on missing deps (1), auth
# failure (2), a CLI-reported error event (3), or the review command's own
# non-zero exit (propagated verbatim).

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

# Capture the full review to a temp file first (single blocking write) so
# error-event detection and finding normalization both read the complete,
# final output. No process-substitution/pipeline race between the two checks.
RAW=$(mktemp)
trap 'rm -f "$RAW"' EXIT
coderabbit review --agent --base "$BASE" "$@" >"$RAW"

# type=="error" events can appear on stdout even when the CLI's own exit code
# is 0. Surface them on stderr and fail loudly instead of letting the
# finding-only filter below silently discard them.
ERRLINES=$(jq -c 'select(.type == "error")' "$RAW")
if [ -n "$ERRLINES" ]; then
	printf '%s\n' "$ERRLINES" >&2
	exit 3
fi

# Normalize output to the shared finding schema.
# Filters only type=="finding" lines; status/context/heartbeat/complete lines
# are discarded.
# Actual CLI schema: fileName, codegenInstructions, suggestions[], severity (label).
# Severity labels confirmed live: critical/major/minor. "nitpick" (this
# script's original mapping) and "trivial"/"info" (docs.coderabbit.ai) are
# both mapped defensively for the low end since we can't yet confirm which
# spelling the installed CLI version emits without an expensive live review.
# Output schema: {id, file, line, severity, title, body, suggested_fix, source}
jq -c 'select(.type == "finding")' "$RAW" \
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
            elif .severity == "trivial"  then 2
            elif .severity == "info"     then 1
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
