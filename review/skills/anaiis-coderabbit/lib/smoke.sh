#!/usr/bin/env bash
# Smoke tests for anaiis-coderabbit.
# Run from the skill root: bash lib/smoke.sh
# Exits 0 if all tests pass, non-zero on first failure.

set -euo pipefail

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${SKILL_ROOT}/lib"
FIXTURES="${LIB}/fixtures"
TMP=$(mktemp -d)
PASS=0
FAIL=0

pass() {
	printf '[PASS] %s\n' "$1"
	PASS=$((PASS + 1))
}
fail() {
	printf '[FAIL] %s\n' "$1"
	FAIL=$((FAIL + 1))
}

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# S1: Normalizer fixture test
# ---------------------------------------------------------------------------
s1() {
	local inline="${FIXTURES}/pr-comments.json"
	local out_inline="${TMP}/pr-inline.json"
	local out_summary="${TMP}/pr-summary.json"
	local out_ndjson="${TMP}/findings.ndjson"

	jq '.inline' "$inline" >"$out_inline"
	jq '.summary' "$inline" >"$out_summary"

	uv run --quiet "${LIB}/parse-pr-comments.py" "42" \
		"$out_inline" "$out_summary" "$out_ndjson" 2>/dev/null

	local count
	count=$(wc -l <"$out_ndjson" | tr -d ' ')
	if [ "$count" -ne 6 ]; then
		fail "S1: expected 6 findings, got ${count}"
		return
	fi

	# Every record must have required fields
	local bad
	bad=$(jq -c 'select(.id == null or .severity == null or .source == null)' "$out_ndjson" | wc -l | tr -d ' ')
	if [ "$bad" -ne 0 ]; then
		fail "S1: ${bad} records missing required fields"
		return
	fi

	pass "S1: normalizer fixture (6 findings, all schema-valid)"
}

# ---------------------------------------------------------------------------
# S2: Ledger idempotency
# ---------------------------------------------------------------------------
s2() {
	local ledger="${TMP}/test.jsonl"
	export LEDGER="$ledger"

	# Source ledger helpers; override LEDGER_DIR so the test stays in $TMP
	# shellcheck source=lib/ledger.sh
	source "${LIB}/ledger.sh"
	LEDGER_DIR="$TMP"

	# Simulate three already-handled IDs
	printf '{"event":"verified","id":"PR-99-1001"}\n' >"$ledger"
	printf '{"event":"skip","id":"PR-99-1002","severity":2,"rationale":"nitpick"}\n' >>"$ledger"
	printf '{"event":"verified","id":"PR-99-1003"}\n' >>"$ledger"

	# Build a findings list: 3 handled + 2 new
	local findings="${TMP}/findings2.ndjson"
	printf '{"id":"PR-99-1001","severity":4}\n' >"$findings"
	printf '{"id":"PR-99-1002","severity":2}\n' >>"$findings"
	printf '{"id":"PR-99-1003","severity":5}\n' >>"$findings"
	printf '{"id":"PR-99-1004","severity":3}\n' >>"$findings"
	printf '{"id":"PR-99-1005","severity":4}\n' >>"$findings"

	local handled
	handled=$(ledger_handled_ids "99")

	local new_count=0
	while IFS= read -r line; do
		id=$(printf '%s' "$line" | jq -r '.id')
		if ! printf '%s\n' "$handled" | grep -qxF "$id"; then
			new_count=$((new_count + 1))
		fi
	done <"$findings"

	if [ "$new_count" -eq 2 ]; then
		pass "S2: ledger idempotency (2 new of 5 pass through)"
	else
		fail "S2: expected 2 new findings, got ${new_count}"
	fi
}

# ---------------------------------------------------------------------------
# S3: Severity inference table
# ---------------------------------------------------------------------------
s3() {
	local inline="${FIXTURES}/pr-comments.json"
	local out_inline="${TMP}/s3-inline.json"
	local out_summary="${TMP}/s3-summary.json"
	local out_ndjson="${TMP}/s3-findings.ndjson"

	jq '.inline' "$inline" >"$out_inline"
	jq '.summary' "$inline" >"$out_summary"

	uv run --quiet "${LIB}/parse-pr-comments.py" "1" \
		"$out_inline" "$out_summary" "$out_ndjson" 2>/dev/null

	# Expected severities by comment id
	declare -A expected=(
		["PR-1-1001"]=4
		["PR-1-1002"]=2
		["PR-1-1003"]=3
		["PR-1-1004"]=5
		["PR-1-1005"]=2
		["PR-1-2001"]=2
	)

	local errors=0
	for id in "${!expected[@]}"; do
		local got
		got=$(jq -r --arg id "$id" 'select(.id == $id) | .severity' "$out_ndjson")
		if [ "$got" != "${expected[$id]}" ]; then
			printf '  MISMATCH %s: expected %s, got %s\n' "$id" "${expected[$id]}" "$got"
			errors=$((errors + 1))
		fi
	done

	if [ "$errors" -eq 0 ]; then
		pass "S3: severity inference (all 6 correct)"
	else
		fail "S3: ${errors} severity mismatches"
	fi
}

# ---------------------------------------------------------------------------
# S4: fetch-pr-findings.sh offline wiring
# ---------------------------------------------------------------------------
s4() {
	if [ "${GH_OFFLINE:-0}" = "1" ]; then
		pass "S4: skipped (GH_OFFLINE=1)"
		return
	fi
	if ! gh auth status >/dev/null 2>&1; then
		pass "S4: skipped (gh not authenticated)"
		return
	fi
	# Verify the script is executable and accepts correct args
	if [ ! -x "${LIB}/fetch-pr-findings.sh" ]; then
		fail "S4: fetch-pr-findings.sh not executable"
		return
	fi
	pass "S4: fetch-pr-findings.sh present and executable (live test requires a real PR)"
}

# ---------------------------------------------------------------------------
# S5: Agent contract drift check
# ---------------------------------------------------------------------------
s5() {
	local plugin_surgeon="${SKILL_ROOT}/../../agents/code-surgeon.md"
	local global_surgeon="${HOME}/.claude/agents/code-surgeon.md"
	local triage="${SKILL_ROOT}/agents/coderabbit-triage.md"

	# coderabbit-triage must have JSON output sentinel
	if ! grep -q '"severity"' "$triage" 2>/dev/null; then
		fail "S5: coderabbit-triage.md missing JSON output contract sentinel"
		return
	fi

	# Drift check (warning only)
	if [ -f "$global_surgeon" ] && [ -f "$plugin_surgeon" ]; then
		if ! diff -q "$plugin_surgeon" "$global_surgeon" >/dev/null 2>&1; then
			printf '[WARN] S5: review/agents/code-surgeon.md has drifted from ~/.claude/agents/code-surgeon.md\n'
		fi
	fi

	pass "S5: agent contracts present"
}

# ---------------------------------------------------------------------------
# Run all
# ---------------------------------------------------------------------------
printf '=== anaiis-coderabbit smoke tests ===\n'
s1
s2
s3
s4
s5

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
