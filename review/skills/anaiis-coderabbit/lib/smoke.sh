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

	# Simulate three already-handled IDs (intent_verified is terminal; bare verified is not)
	printf '{"event":"intent_verified","id":"PR-99-1001"}\n' >"$ledger"
	printf '{"event":"skip","id":"PR-99-1002","severity":2,"rationale":"nitpick"}\n' >>"$ledger"
	printf '{"event":"intent_verified","id":"PR-99-1003"}\n' >>"$ledger"

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
	local fetch="${LIB}/fetch-pr-findings.sh"
	local errors=0

	if [ ! -x "$fetch" ]; then
		fail "S4: fetch-pr-findings.sh not executable"
		return
	fi

	# Syntax check
	if ! bash -n "$fetch" 2>/dev/null; then
		printf '  FAIL S4.1: fetch-pr-findings.sh has bash syntax errors\n'
		errors=$((errors + 1))
	fi

	# Wiring: must call gh api (data source) and parse-pr-comments.py (normalizer)
	if ! grep -q 'gh api' "$fetch"; then
		printf '  FAIL S4.2: fetch-pr-findings.sh does not call gh api\n'
		errors=$((errors + 1))
	fi
	# Output contract: must write the files parse-pr-comments.py expects as input
	for outfile in 'pr-inline.json' 'pr-summary.json'; do
		if ! grep -q "$outfile" "$fetch"; then
			printf '  FAIL S4.3: fetch-pr-findings.sh missing output file reference: %s\n' "$outfile"
			errors=$((errors + 1))
		fi
	done

	if [ "$errors" -eq 0 ]; then
		pass "S4: fetch-pr-findings.sh syntax valid, wiring to gh api and parse-pr-comments.py confirmed"
	else
		fail "S4: fetch-pr-findings.sh (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S5: Agent contract drift check
# ---------------------------------------------------------------------------
s5() {
	local plugin_surgeon="${SKILL_ROOT}/../../agents/code-surgeon.md"
	local global_surgeon="${HOME}/.claude/agents/code-surgeon.md"
	local triage="${SKILL_ROOT}/agents/coderabbit-triage.md"
	local verifier="${SKILL_ROOT}/agents/intent-verifier.md"

	local errors=0

	# coderabbit-triage must have all three output contract fields
	for field in '"severity"' '"decision"' '"rationale"'; do
		if ! grep -q "$field" "$triage" 2>/dev/null; then
			printf '  FAIL S5.1: coderabbit-triage.md missing output field %s\n' "$field"
			errors=$((errors + 1))
		fi
	done

	# intent-verifier must be present (added in 0.1.1)
	if [ ! -f "$verifier" ]; then
		printf '  FAIL S5.2: agents/intent-verifier.md not found\n'
		errors=$((errors + 1))
	fi

	# Plugin cache copy of code-surgeon must match the repo (authoritative comparison).
	# The cache path encodes the plugin version; derive it from plugin.json.
	local version
	version=$(jq -r '.version' "${SKILL_ROOT}/../../.claude-plugin/plugin.json" 2>/dev/null)
	local cache_surgeon="${HOME}/.claude/plugins/cache/anaiis-plugins/anaiis-review/${version}/agents/code-surgeon.md"
	if [ -f "$cache_surgeon" ]; then
		if ! diff -q "$plugin_surgeon" "$cache_surgeon" >/dev/null 2>&1; then
			printf '[WARN] S5.3: review/agents/code-surgeon.md has drifted from plugin cache (%s). Refresh the plugin.\n' "$version"
		fi
	else
		printf '[WARN] S5.3: plugin cache not found at %s -- plugin may need installing or refreshing.\n' "$cache_surgeon"
	fi

	# If ~/.claude/agents/code-surgeon.md is a file-level symlink it bypasses the dotfiles
	# layer and creates a tight coupling to the plugin repo path.
	if [ -L "$global_surgeon" ]; then
		local target
		target=$(readlink "$global_surgeon")
		printf '  FAIL S5.4: ~/.claude/agents/code-surgeon.md is a file-level symlink (-> %s).\n' "$target"
		printf '       Remove it; the plain file in dotfiles resolves automatically: rm %s\n' "$global_surgeon"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S5: agent contracts present"
	else
		fail "S5: agent contracts (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S6: intent-preflight.sh fixture checks
# ---------------------------------------------------------------------------
s6() {
	local preflight="${LIB}/intent-preflight.sh"
	local fixtures="${FIXTURES}/preflight"

	if [ ! -x "$preflight" ]; then
		fail "S6: intent-preflight.sh not executable"
		return
	fi

	local errors=0 reason

	# 1. Named file touched, hunk in range, real code change -> PASS
	if ! INTENT_PREFLIGHT_DIFF="${fixtures}/edit-touches-named-file.diff" \
		bash "$preflight" "R/analysis.R" 10 12 >/dev/null 2>&1; then
		printf '  FAIL S6.1: edit-touches-named-file should pass preflight\n'
		errors=$((errors + 1))
	fi

	# 2. Empty diff (surgeon edited a different file) -> FAIL preflight:wrong-file
	if reason=$(INTENT_PREFLIGHT_DIFF="${fixtures}/edit-touches-different-file.diff" \
		bash "$preflight" "R/analysis.R" 10 12 2>&1); then
		printf '  FAIL S6.2: edit-touches-different-file should fail preflight\n'
		errors=$((errors + 1))
	elif [ "$reason" != "preflight:wrong-file" ]; then
		printf '  FAIL S6.2: wrong reason (got %s, want preflight:wrong-file)\n' "$reason"
		errors=$((errors + 1))
	fi

	# 3. Comment-only change -> FAIL preflight:comment-only
	if reason=$(INTENT_PREFLIGHT_DIFF="${fixtures}/edit-is-comment-only.diff" \
		bash "$preflight" "R/analysis.R" 10 12 2>&1); then
		printf '  FAIL S6.3: edit-is-comment-only should fail preflight\n'
		errors=$((errors + 1))
	elif [ "$reason" != "preflight:comment-only" ]; then
		printf '  FAIL S6.3: wrong reason (got %s, want preflight:comment-only)\n' "$reason"
		errors=$((errors + 1))
	fi

	# 4. Edit at line 26 overlaps finding at line 10 via +-20 window -> PASS
	if ! INTENT_PREFLIGHT_DIFF="${fixtures}/edit-overlaps-line-range.diff" \
		bash "$preflight" "R/analysis.R" 10 12 >/dev/null 2>&1; then
		printf '  FAIL S6.4: edit-overlaps-line-range should pass preflight\n'
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S6: intent-preflight (4 fixture checks: 2 pass, 2 fail-with-reason)"
	else
		fail "S6: intent-preflight (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S7: intent-verifier agent contract check (structural; judgment is reviewed not tested)
# Set INTENT_JUDGMENT_SMOKE=1 to also print the manual verification scenario.
# ---------------------------------------------------------------------------
s7() {
	local verifier="${SKILL_ROOT}/agents/intent-verifier.md"
	local jp="${FIXTURES}/judgment-pairs"

	if [ ! -f "$verifier" ]; then
		fail "S7: agents/intent-verifier.md not found"
		return
	fi

	local errors=0

	# Frontmatter: correct model tier for a judgment task
	if ! grep -q 'model: claude-sonnet-4-6' "$verifier"; then
		printf '  FAIL S7.1: intent-verifier.md missing model: claude-sonnet-4-6\n'
		errors=$((errors + 1))
	fi

	# Output contract: both fields must be present
	for field in '"intent_met"' '"rationale"'; do
		if ! grep -q "$field" "$verifier"; then
			printf '  FAIL S7.2: intent-verifier.md missing output field %s\n' "$field"
			errors=$((errors + 1))
		fi
	done

	# Failure-bias directive: must name the declarative-sentence rule
	if ! grep -q 'declarative' "$verifier"; then
		printf '  FAIL S7.3: intent-verifier.md missing declarative-sentence directive\n'
		errors=$((errors + 1))
	fi

	# Hedging-language directive must be present
	if ! grep -q 'hedging\|appears to\|Hedging' "$verifier"; then
		printf '  FAIL S7.4: intent-verifier.md missing hedging-language failure rule\n'
		errors=$((errors + 1))
	fi

	# Verifier must be read-only: Edit and Bash are forbidden in the tools list
	if grep -qE '^\s+- (Edit|Bash)' "$verifier"; then
		printf '  FAIL S7.5: intent-verifier.md has write-capable tool (Edit or Bash); verifier must be read-only\n'
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S7: intent-verifier agent contract (model tier, output format, bias directives)"
	else
		fail "S7: intent-verifier contract (${errors} sentinel checks failed)"
	fi

	# Optional: print manual verification scenario
	if [ "${INTENT_JUDGMENT_SMOKE:-0}" = "1" ]; then
		printf '\n--- S7 manual verification scenario ---\n'
		printf 'Finding:\n'
		cat "${jp}/finding.json"
		printf '\nExpected: good-fix.diff -> intent_met: true\n'
		cat "${jp}/good-fix.diff"
		printf '\nExpected: bad-fix.diff -> intent_met: false\n'
		cat "${jp}/bad-fix.diff"
		printf '\nRun the skill against a branch with the bad-fix applied and confirm\n'
		printf 'the ledger contains an intent_failed event for this finding.\n'
		printf '---\n\n'
	fi
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
s6
s7

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
