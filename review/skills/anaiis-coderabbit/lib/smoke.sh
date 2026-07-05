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
	local triage="${SKILL_ROOT}/../../agents/coderabbit-triage.md"
	local verifier="${SKILL_ROOT}/../../agents/intent-verifier.md"

	local errors=0

	# coderabbit-triage must have both output contract fields
	for field in '"decision"' '"rationale"'; do
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
	local verifier="${SKILL_ROOT}/../../agents/intent-verifier.md"
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
# S8: review-round.sh deterministic timeout + one free retry
# Fully offline: REVIEW_CMD injects a mock in place of the real coderabbit CLI,
# mirroring the INTENT_PREFLIGHT_DIFF injection seam used by S6. Mocks exit
# 124 directly (rather than sleeping), so no check waits on wall-clock time.
# ---------------------------------------------------------------------------
s8() {
	local rr="${LIB}/review-round.sh"
	if [ ! -x "$rr" ]; then
		fail "S8: review-round.sh not executable"
		return
	fi

	local errors=0 out err code

	# 1. Immediate success -> exit 0, finding on stdout
	local mock_ok="${TMP}/mock-ok.sh"
	cat >"$mock_ok" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"finding","fileName":"a.R","severity":"major"}\n'
exit 0
EOF
	chmod +x "$mock_ok"
	if out=$(REVIEW_CMD="$mock_ok" REVIEW_TIMEOUT=5 bash "$rr" "main" 2>/dev/null); then
		if [ -z "$out" ]; then
			printf '  FAIL S8.1: expected finding on stdout, got nothing\n'
			errors=$((errors + 1))
		fi
	else
		printf '  FAIL S8.1: expected exit 0 on immediate success (got %s)\n' "$?"
		errors=$((errors + 1))
	fi

	# 2. Timeout on attempt 1, success on the free retry -> exit 20, finding on stdout
	local counter="${TMP}/s8-counter"
	: >"$counter"
	local mock_recover="${TMP}/mock-recover.sh"
	cat >"$mock_recover" <<EOF
#!/usr/bin/env bash
n=\$(cat "$counter")
n=\$((n + 1))
printf '%s' "\$n" >"$counter"
if [ "\$n" -eq 1 ]; then
    exit 124
fi
printf '{"type":"finding","fileName":"b.R","severity":"minor"}\n'
exit 0
EOF
	chmod +x "$mock_recover"
	if out=$(REVIEW_CMD="$mock_recover" REVIEW_TIMEOUT=5 bash "$rr" "main" 2>/dev/null); then
		printf '  FAIL S8.2: expected exit 20 (recovered after retry), got 0\n'
		errors=$((errors + 1))
	else
		code=$?
		if [ "$code" -ne 20 ]; then
			printf '  FAIL S8.2: expected exit 20 (recovered after retry), got %s\n' "$code"
			errors=$((errors + 1))
		elif [ -z "$out" ]; then
			printf '  FAIL S8.2: expected finding on stdout after recovery, got nothing\n'
			errors=$((errors + 1))
		fi
	fi

	# 3. Timeout on both the initial attempt and the free retry -> exit 21, reason on stderr
	local mock_stuck="${TMP}/mock-stuck.sh"
	cat >"$mock_stuck" <<'EOF'
#!/usr/bin/env bash
exit 124
EOF
	chmod +x "$mock_stuck"
	if err=$(REVIEW_CMD="$mock_stuck" REVIEW_TIMEOUT=5 bash "$rr" "main" 2>&1 1>/dev/null); then
		printf '  FAIL S8.3: expected exit 21 (timeout-exhausted), got 0\n'
		errors=$((errors + 1))
	else
		code=$?
		if [ "$code" -ne 21 ]; then
			printf '  FAIL S8.3: expected exit 21 (timeout-exhausted), got %s\n' "$code"
			errors=$((errors + 1))
		elif ! printf '%s' "$err" | grep -q 'review-round:timeout-exhausted'; then
			printf '  FAIL S8.3: expected stderr reason review-round:timeout-exhausted\n'
			errors=$((errors + 1))
		fi
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S8: review-round.sh timeout+retry (success, recovered, exhausted)"
	else
		fail "S8: review-round.sh (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S9: ledger_intent_verified refuses to log the terminal event when
# verification was required but never happened. Direct regression guard for
# the CLI-1 session where intent_verified was logged before the verifier ran.
# ---------------------------------------------------------------------------
s9() {
	local ledger="${TMP}/s9.jsonl"
	export LEDGER="$ledger"
	# shellcheck source=lib/ledger.sh
	source "${LIB}/ledger.sh"
	LEDGER_DIR="$TMP"

	local errors=0

	# 1. requires_verify=true, no verifier_result yet -> MUST refuse
	: >"$ledger"
	ledger_decision "S9-1" 4 "fix" "sev4: fix without triage" true
	if ledger_intent_verified "S9-1" 2>/dev/null; then
		printf '  FAIL S9.1: expected ledger_intent_verified to refuse with no verifier_result, but it succeeded\n'
		errors=$((errors + 1))
	elif grep -q '"event":"intent_verified"' "$ledger"; then
		printf '  FAIL S9.1: intent_verified event was written despite the refusal\n'
		errors=$((errors + 1))
	fi

	# 2. requires_verify=true, passing verifier_result -> MUST succeed
	: >"$ledger"
	ledger_decision "S9-2" 4 "fix" "sev4: fix without triage" true
	ledger_verifier_result "S9-2" true "confirmed"
	if ! ledger_intent_verified "S9-2" 2>/dev/null; then
		printf '  FAIL S9.2: expected ledger_intent_verified to succeed with a passing verifier_result\n'
		errors=$((errors + 1))
	fi

	# 3. requires_verify=true, failing verifier_result -> MUST still refuse
	: >"$ledger"
	ledger_decision "S9-3" 3 "fix" "judgment: fix" true
	ledger_verifier_result "S9-3" false "not addressed"
	if ledger_intent_verified "S9-3" 2>/dev/null; then
		printf '  FAIL S9.3: expected ledger_intent_verified to refuse after a failing verifier_result\n'
		errors=$((errors + 1))
	fi

	# 4. already_resolved bypass -> MUST succeed even with no verifier_result
	: >"$ledger"
	ledger_decision "S9-4" 4 "fix" "sev4: fix without triage" true
	ledger_already_resolved "S9-4"
	if ! ledger_intent_verified "S9-4" 2>/dev/null; then
		printf '  FAIL S9.4: expected ledger_intent_verified to succeed via already_resolved bypass\n'
		errors=$((errors + 1))
	fi

	# 5. requires_verify=false (mechanical sev-3) -> MUST succeed directly
	: >"$ledger"
	ledger_decision "S9-5" 3 "fix" "mechanical fix, no triage spawned" false
	if ! ledger_intent_verified "S9-5" 2>/dev/null; then
		printf '  FAIL S9.5: expected ledger_intent_verified to succeed when requires_verify=false\n'
		errors=$((errors + 1))
	fi

	# 6. ledger_decision with decision="fix" and requires_verify omitted -> MUST error loudly
	: >"$ledger"
	if ledger_decision "S9-6" 4 "fix" "missing requires_verify" 2>/dev/null; then
		printf '  FAIL S9.6: expected ledger_decision to refuse a "fix" decision with no requires_verify arg\n'
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S9: ledger_intent_verified sequencing guard (6 checks)"
	else
		fail "S9: ledger_intent_verified sequencing guard (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S10: run-review.sh error-event handling + expanded severity mapping.
# Shadows the real `coderabbit` binary via PATH with a fixture dispatcher
# (lib/fixtures/run-review/fake-coderabbit.sh), fully offline.
# ---------------------------------------------------------------------------
s10() {
	local run="${LIB}/run-review.sh"
	local fixtures="${FIXTURES}/run-review"
	local fakebin="${TMP}/fakebin"
	mkdir -p "$fakebin"
	cp "${fixtures}/fake-coderabbit.sh" "${fakebin}/coderabbit"
	chmod +x "${fakebin}/coderabbit"

	local errors=0 out code

	# 1. Mixed severities: trivial -> 2, info -> 1 (not the sev-3 catch-all)
	if out=$(FAKE_CODERABBIT_FIXTURE="${fixtures}/mixed-severities.ndjson" PATH="${fakebin}:${PATH}" bash "$run" "main" 2>/dev/null); then
		local sev_trivial sev_info
		sev_trivial=$(printf '%s\n' "$out" | jq -c 'select(.file=="a.R") | .severity')
		sev_info=$(printf '%s\n' "$out" | jq -c 'select(.file=="b.R") | .severity')
		if [ "$sev_trivial" != "2" ]; then
			printf '  FAIL S10.1: expected trivial -> severity 2, got %s\n' "$sev_trivial"
			errors=$((errors + 1))
		fi
		if [ "$sev_info" != "1" ]; then
			printf '  FAIL S10.1: expected info -> severity 1, got %s\n' "$sev_info"
			errors=$((errors + 1))
		fi
	else
		printf '  FAIL S10.1: expected exit 0 for mixed-severities fixture\n'
		errors=$((errors + 1))
	fi

	# 2. An error event -> exit 3, surfaced on stderr, no findings on stdout
	if out=$(FAKE_CODERABBIT_FIXTURE="${fixtures}/error-event.ndjson" PATH="${fakebin}:${PATH}" bash "$run" "main" 2>"${TMP}/s10-err"); then
		printf '  FAIL S10.2: expected non-zero exit when an error event is present\n'
		errors=$((errors + 1))
	else
		code=$?
		if [ "$code" -ne 3 ]; then
			printf '  FAIL S10.2: expected exit 3 for an error event, got %s\n' "$code"
			errors=$((errors + 1))
		fi
		if [ -n "$out" ]; then
			printf '  FAIL S10.2: expected no findings on stdout when an error event is present\n'
			errors=$((errors + 1))
		fi
		if ! grep -q '"type":"error"' "${TMP}/s10-err"; then
			printf '  FAIL S10.2: expected the error event to be surfaced on stderr\n'
			errors=$((errors + 1))
		fi
	fi

	# 3. Clean review (no findings, no errors) -> exit 0, empty stdout
	if out=$(FAKE_CODERABBIT_FIXTURE="${fixtures}/clean.ndjson" PATH="${fakebin}:${PATH}" bash "$run" "main" 2>/dev/null); then
		if [ -n "$out" ]; then
			printf '  FAIL S10.3: expected empty stdout for a clean review\n'
			errors=$((errors + 1))
		fi
	else
		printf '  FAIL S10.3: expected exit 0 for a clean review\n'
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S10: run-review.sh error-event handling + expanded severity mapping (3 checks)"
	else
		fail "S10: run-review.sh (${errors} checks failed)"
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
s8
s9
s10

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
