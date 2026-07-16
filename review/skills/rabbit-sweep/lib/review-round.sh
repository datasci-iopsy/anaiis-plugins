#!/usr/bin/env bash
# Deterministic timeout + one free retry for a single review round.
#
# A timeout (exit 124) on the first attempt triggers exactly one immediate
# retry under the same timeout. The retry does not create a new round; the
# caller (references/phases.md Phase 3 / Phase 7) only advances its round
# counter when this script exits 0 or 20.
#
# Usage: review-round.sh <base> [--type <type>] [--dir <path>]
# Env:
#   REVIEW_TIMEOUT  per-attempt timeout in seconds (default 1800 = 30 min).
#                   CodeRabbit's own docs state reviews take 7 to 30+ minutes
#                   depending on scope (docs.coderabbit.ai/cli/claude-code-integration);
#                   a short timeout kills normal reviews, not just hangs.
#   REVIEW_CMD      command that runs the review (default: run-review.sh);
#                   overridable for tests, mirrors intent-preflight.sh's
#                   INTENT_PREFLIGHT_DIFF injection seam.
# Exit codes:
#   0   success on the first attempt; stdout carries NDJSON (empty == clean)
#   20  success, but only after the free retry (auditable retry signal)
#   21  timeout-exhausted: both the initial attempt and the retry timed out
#   *   any other non-timeout error, propagated verbatim from the review command
set -euo pipefail

BASE="${1:-}"
if [ -z "$BASE" ]; then
	echo "Usage: review-round.sh <base> [--type <type>] [--dir <path>]" >&2
	exit 1
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-1800}"
REVIEW_CMD="${REVIEW_CMD:-bash ${LIB_DIR}/run-review.sh}"

TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

run_attempt() {
	# shellcheck disable=SC2086  # REVIEW_CMD is intentionally word-split (e.g. "bash x.sh")
	timeout "$REVIEW_TIMEOUT" $REVIEW_CMD "$@" >"$TMP_OUT"
}

code=0
run_attempt "$@" || code=$?

if [ "$code" -eq 0 ]; then
	cat "$TMP_OUT"
	exit 0
fi

if [ "$code" -ne 124 ]; then
	exit "$code"
fi

# First attempt timed out: one free retry, same timeout. Discard the
# (empty/partial) output from the failed attempt first.
: >"$TMP_OUT"
code=0
run_attempt "$@" || code=$?

if [ "$code" -eq 0 ]; then
	cat "$TMP_OUT"
	exit 20
fi

if [ "$code" -eq 124 ]; then
	echo "review-round:timeout-exhausted" >&2
	exit 21
fi

exit "$code"
