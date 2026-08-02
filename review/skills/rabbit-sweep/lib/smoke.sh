#!/usr/bin/env bash
# Smoke tests for rabbit-sweep.
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

	local errors=0
	if [ "$new_count" -ne 2 ]; then
		printf '  FAIL S2.1: expected 2 new findings, got %s\n' "$new_count"
		errors=$((errors + 1))
	fi

	# A corrupt ledger file must not poison the stream: terminal events after
	# a malformed line (same file or later files) must still be returned.
	local corrupt="${TMP}/corrupt.jsonl"
	printf '{"event":"intent_verified","id":"PR-99-\n' >"$corrupt"
	printf '{"event":"skip","id":"PR-99-1006","severity":2,"rationale":"after corrupt line"}\n' >>"$corrupt"

	handled=$(ledger_handled_ids "99") || true
	for id in "PR-99-1006" "PR-99-1001"; do
		if ! printf '%s\n' "$handled" | grep -qxF "$id"; then
			printf '  FAIL S2.2: %s missing from handled IDs when a corrupt ledger file is present\n' "$id"
			errors=$((errors + 1))
		fi
	done
	rm -f "$corrupt"

	if [ "$errors" -eq 0 ]; then
		pass "S2: ledger idempotency (2 new of 5 pass through; corrupt-file tolerant)"
	else
		fail "S2: ledger idempotency (${errors} checks failed)"
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
# S4: fetch-pr-findings.sh fixture execution
# Fully offline: shadows gh on PATH (same seam pattern as S10's
# fake-coderabbit) with a mock that returns raw GitHub API comment payloads,
# then runs the real fetcher end to end and normalizes its output with
# parse-pr-comments.py.
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

	local raw_pulls="${TMP}/s4-raw-pulls.json"
	local raw_issues="${TMP}/s4-raw-issues.json"
	cat >"$raw_pulls" <<'EOF'
[
    {
        "id": 3540349623,
        "path": "R/analysis.R",
        "line": 42,
        "original_line": 42,
        "body": "_Potential issue_\n\nThe `mean()` call does not pass `na.rm = TRUE`.\n\n```suggestion\nmean(x, na.rm = TRUE)\n```",
        "diff_hunk": "@@ -40,3 +40,3 @@",
        "commit_id": "abc123",
        "user": {"login": "coderabbitai[bot]"}
    },
    {
        "id": 9999999,
        "path": "R/analysis.R",
        "line": 10,
        "original_line": 10,
        "body": "human review comment, must be filtered out",
        "diff_hunk": "@@ -8,3 +8,3 @@",
        "commit_id": "abc123",
        "user": {"login": "someone-else"}
    }
]
EOF
	cat >"$raw_issues" <<'EOF'
[
    {
        "id": 4910018180,
        "body": "## Walkthrough\n\nThis PR adds new analysis functions.",
        "user": {"login": "coderabbitai[bot]"}
    },
    {
        "id": 4910099999,
        "body": "human summary comment, must be filtered out",
        "user": {"login": "human-reviewer"}
    }
]
EOF

	local fakebin="${TMP}/s4-fakebin"
	mkdir -p "$fakebin"
	local mock_gh="${fakebin}/gh"
	cat >"$mock_gh" <<EOF
#!/usr/bin/env bash
case "\$1" in
	auth)
		exit 0
		;;
	api)
		case "\$2" in
			*pulls*)
				cat "$raw_pulls"
				;;
			*issues*)
				cat "$raw_issues"
				;;
			*)
				exit 1
				;;
		esac
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "$mock_gh"

	local out="${TMP}/s4-out"
	mkdir -p "$out"
	if ! PATH="${fakebin}:${PATH}" bash "$fetch" "owner/repo" 5 "$out" >/dev/null 2>&1; then
		printf '  FAIL S4.2: fetch-pr-findings.sh exited non-zero against the mocked gh\n'
		errors=$((errors + 1))
	elif [ ! -f "${out}/pr-inline.json" ] || [ ! -f "${out}/pr-summary.json" ]; then
		printf '  FAIL S4.3: pr-inline.json and/or pr-summary.json were not written\n'
		errors=$((errors + 1))
	else
		local inline_count summary_count
		inline_count=$(jq 'length' "${out}/pr-inline.json")
		summary_count=$(jq 'length' "${out}/pr-summary.json")
		if [ "$inline_count" -ne 1 ]; then
			printf '  FAIL S4.4: expected 1 bot-authored inline comment (non-bot filtered out), got %s\n' "$inline_count"
			errors=$((errors + 1))
		fi
		if [ "$summary_count" -ne 1 ]; then
			printf '  FAIL S4.4: expected 1 bot-authored summary comment (non-bot filtered out), got %s\n' "$summary_count"
			errors=$((errors + 1))
		fi

		local ndjson="${TMP}/s4-findings.ndjson"
		uv run --quiet "${LIB}/parse-pr-comments.py" "5" \
			"${out}/pr-inline.json" "${out}/pr-summary.json" "$ndjson" 2>/dev/null

		local count
		count=$(wc -l <"$ndjson" | tr -d ' ')
		if [ "$count" -ne 2 ]; then
			printf '  FAIL S4.5: expected 2 normalized findings, got %s\n' "$count"
			errors=$((errors + 1))
		fi
		if ! jq -e 'select(.id == "PR-5-3540349623" and .severity == 4)' "$ndjson" >/dev/null 2>&1; then
			printf '  FAIL S4.5: expected finding PR-5-3540349623 with severity 4\n'
			errors=$((errors + 1))
		fi
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S4: fetch-pr-findings.sh fixture execution (gh mocked, output written, normalized by parse-pr-comments.py)"
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

	# Untrusted-input guardrail: every agent that receives CodeRabbit comment
	# text must carry the sentinel stating that content is untrusted input.
	for agent_file in "$plugin_surgeon" "$triage" "$verifier"; do
		if ! grep -qi 'untrusted' "$agent_file" 2>/dev/null; then
			printf '  FAIL S5.5: %s missing untrusted-input guardrail\n' "$(basename "$agent_file")"
			errors=$((errors + 1))
		fi
	done

	# If ~/.claude/agents/code-surgeon.md is a file-level symlink it bypasses the dotfiles
	# layer and creates a tight coupling to the plugin repo path.
	if [ -L "$global_surgeon" ]; then
		local target
		target=$(readlink "$global_surgeon")
		printf '  FAIL S5.4: ~/.claude/agents/code-surgeon.md is a file-level symlink (-> %s).\n' "$target"
		printf '       Remove it; the plain file in dotfiles resolves automatically: rm %s\n' "$global_surgeon"
		errors=$((errors + 1))
	fi

	# code-surgeon must have Bash and a self-test obligation for touched test files.
	if ! grep -q '^[[:space:]]*-[[:space:]]*Bash[[:space:]]*$' "$plugin_surgeon" 2>/dev/null; then
		printf '  FAIL S5.6: code-surgeon.md tools frontmatter missing Bash\n'
		errors=$((errors + 1))
	fi
	if ! grep -qi "the project.s test command" "$plugin_surgeon" 2>/dev/null; then
		printf '  FAIL S5.7: code-surgeon.md missing self-test obligation instruction\n'
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

	# 5. Comment-only diff, no suggested-fix context -> FAIL preflight:comment-only (unchanged regression guard)
	if reason=$(INTENT_PREFLIGHT_DIFF="${fixtures}/comment-only-fix.diff" \
		bash "$preflight" "R/analysis.R" 10 12 2>&1); then
		printf '  FAIL S6.5: comment-only-fix with no suggested-fix context should fail preflight\n'
		errors=$((errors + 1))
	elif [ "$reason" != "preflight:comment-only" ]; then
		printf '  FAIL S6.5: wrong reason (got %s, want preflight:comment-only)\n' "$reason"
		errors=$((errors + 1))
	fi

	# 6. Comment-only diff, suggested fix is ALSO comment-only -> PASS (the finding was about a comment)
	if ! INTENT_PREFLIGHT_DIFF="${fixtures}/comment-only-fix.diff" \
		INTENT_PREFLIGHT_SUGGESTED_FIX=$'# compute the mean, ignoring missing values' \
		bash "$preflight" "R/analysis.R" 10 12 >/dev/null 2>&1; then
		printf '  FAIL S6.6: comment-only-fix should pass when suggested_fix is itself comment-only\n'
		errors=$((errors + 1))
	fi

	# 7. Comment-only diff, but suggested fix is real code -> still FAIL (surgeon's diff doesn't match what was expected)
	if reason=$(INTENT_PREFLIGHT_DIFF="${fixtures}/comment-only-fix.diff" \
		INTENT_PREFLIGHT_SUGGESTED_FIX='mean(items, na.rm = TRUE)' \
		bash "$preflight" "R/analysis.R" 10 12 2>&1); then
		printf '  FAIL S6.7: comment-only-fix should still fail when suggested_fix is real code\n'
		errors=$((errors + 1))
	elif [ "$reason" != "preflight:comment-only" ]; then
		printf '  FAIL S6.7: wrong reason (got %s, want preflight:comment-only)\n' "$reason"
		errors=$((errors + 1))
	fi

	# 8. Comment-only diff, empty suggested-fix env var -> still FAIL (guard against trivial bypass)
	if reason=$(INTENT_PREFLIGHT_DIFF="${fixtures}/comment-only-fix.diff" \
		INTENT_PREFLIGHT_SUGGESTED_FIX='' \
		bash "$preflight" "R/analysis.R" 10 12 2>&1); then
		printf '  FAIL S6.8: comment-only-fix should still fail with an empty suggested-fix env var\n'
		errors=$((errors + 1))
	elif [ "$reason" != "preflight:comment-only" ]; then
		printf '  FAIL S6.8: wrong reason (got %s, want preflight:comment-only)\n' "$reason"
		errors=$((errors + 1))
	fi

	# 9. Literal "null" line args (the shape a naive jq interpolation of a
	# missing field produces) -> FAIL preflight:bad-line-args, not an
	# unbound-variable crash.
	if reason=$(INTENT_PREFLIGHT_DIFF="${fixtures}/edit-touches-named-file.diff" \
		bash "$preflight" "R/analysis.R" null null 2>&1); then
		printf '  FAIL S6.9: null null line args should fail preflight\n'
		errors=$((errors + 1))
	elif [ "$reason" != "preflight:bad-line-args" ]; then
		printf '  FAIL S6.9: wrong reason (got %s, want preflight:bad-line-args)\n' "$reason"
		errors=$((errors + 1))
	fi

	# 10. Empty-string line args -> FAIL preflight:bad-line-args.
	if reason=$(INTENT_PREFLIGHT_DIFF="${fixtures}/edit-touches-named-file.diff" \
		bash "$preflight" "R/analysis.R" "" "" 2>&1); then
		printf '  FAIL S6.10: empty-string line args should fail preflight\n'
		errors=$((errors + 1))
	elif [ "$reason" != "preflight:bad-line-args" ]; then
		printf '  FAIL S6.10: wrong reason (got %s, want preflight:bad-line-args)\n' "$reason"
		errors=$((errors + 1))
	fi

	# 11. Non-numeric line args -> FAIL preflight:bad-line-args.
	if reason=$(INTENT_PREFLIGHT_DIFF="${fixtures}/edit-touches-named-file.diff" \
		bash "$preflight" "R/analysis.R" abc def 2>&1); then
		printf '  FAIL S6.11: non-numeric line args should fail preflight\n'
		errors=$((errors + 1))
	elif [ "$reason" != "preflight:bad-line-args" ]; then
		printf '  FAIL S6.11: wrong reason (got %s, want preflight:bad-line-args)\n' "$reason"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S6: intent-preflight (11 fixture checks: 3 pass, 8 fail-with-reason)"
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
	if ! grep -q 'model: claude-sonnet-5' "$verifier"; then
		printf '  FAIL S7.1: intent-verifier.md missing model: claude-sonnet-5\n'
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

	# Verifier must never be able to edit files directly. Bash is now permitted (A3) but
	# scoped to verification only -- checked below, not forbidden outright.
	if grep -qE '^[[:space:]]+- Edit[[:space:]]*$' "$verifier"; then
		printf '  FAIL S7.5: intent-verifier.md has Edit in its tools list; verifier must never write files\n'
		errors=$((errors + 1))
	fi

	# Bash grant (A3): required so the verifier can run tests instead of guessing statically.
	if ! grep -qE '^[[:space:]]+- Bash[[:space:]]*$' "$verifier"; then
		printf '  FAIL S7.6: intent-verifier.md tools frontmatter missing Bash\n'
		errors=$((errors + 1))
	fi

	# Bash usage must be explicitly scoped to verification only, not general-purpose.
	if ! grep -qi 'verification only' "$verifier"; then
		printf '  FAIL S7.7: intent-verifier.md missing a verification-only Bash usage contract\n'
		errors=$((errors + 1))
	fi
	if ! grep -qi 'mutating git command' "$verifier"; then
		printf '  FAIL S7.7: intent-verifier.md Bash contract missing the no-mutating-git-command rule\n'
		errors=$((errors + 1))
	fi

	# Sharpened failure-mode bias: no-Bash-or-not-executable + test file/new symbol must abstain.
	if ! grep -qi 'cannot execute' "$verifier"; then
		printf '  FAIL S7.8: intent-verifier.md missing the cannot-execute abstain rationale\n'
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S7: intent-verifier agent contract (model tier, output format, bias directives, scoped Bash)"
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

	# 4. coderabbit process itself crashes mid-review -> exit propagated, raw
	# output surfaced on stderr instead of silently discarded.
	if out=$(FAKE_CODERABBIT_FIXTURE="${fixtures}/crash.ndjson" FAKE_CODERABBIT_EXIT_CODE=1 PATH="${fakebin}:${PATH}" bash "$run" "main" 2>"${TMP}/s10-crash-err"); then
		printf '  FAIL S10.4: expected non-zero exit when coderabbit itself crashes\n'
		errors=$((errors + 1))
	else
		code=$?
		if [ "$code" -ne 1 ]; then
			printf '  FAIL S10.4: expected exit 1 when coderabbit itself crashes, got %s\n' "$code"
			errors=$((errors + 1))
		fi
		if [ -n "$out" ]; then
			printf '  FAIL S10.4: expected no findings on stdout when coderabbit itself crashes\n'
			errors=$((errors + 1))
		fi
		if ! grep -q 'review_context' "${TMP}/s10-crash-err"; then
			printf '  FAIL S10.4: expected the raw partial output to be surfaced on stderr\n'
			errors=$((errors + 1))
		fi
	fi

	# 5. line_start/line_end are sourced from the CLI's own startLine/endLine,
	# not discarded to null. mixed-severities.ndjson carries startLine:10,
	# endLine:10 for a.R and startLine:22, endLine:25 for b.R.
	if out=$(FAKE_CODERABBIT_FIXTURE="${fixtures}/mixed-severities.ndjson" PATH="${fakebin}:${PATH}" bash "$run" "main" 2>/dev/null); then
		local ls_a le_a ls_b le_b
		ls_a=$(printf '%s\n' "$out" | jq -c 'select(.file=="a.R") | .line_start')
		le_a=$(printf '%s\n' "$out" | jq -c 'select(.file=="a.R") | .line_end')
		ls_b=$(printf '%s\n' "$out" | jq -c 'select(.file=="b.R") | .line_start')
		le_b=$(printf '%s\n' "$out" | jq -c 'select(.file=="b.R") | .line_end')
		if [ "$ls_a" != "10" ] || [ "$le_a" != "10" ]; then
			printf '  FAIL S10.5: expected a.R line_start=10 line_end=10, got line_start=%s line_end=%s\n' "$ls_a" "$le_a"
			errors=$((errors + 1))
		fi
		if [ "$ls_b" != "22" ] || [ "$le_b" != "25" ]; then
			printf '  FAIL S10.5: expected b.R line_start=22 line_end=25, got line_start=%s line_end=%s\n' "$ls_b" "$le_b"
			errors=$((errors + 1))
		fi
	else
		printf '  FAIL S10.5: expected exit 0 for mixed-severities fixture\n'
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S10: run-review.sh error-event handling + expanded severity mapping (5 checks)"
	else
		fail "S10: run-review.sh (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S11: reply-skip.sh source guard, id parse, and gh POST wiring.
# Fully offline: REPLY_SKIP_GH injects a mock in place of the real gh CLI,
# mirroring the REVIEW_CMD injection seam used by S8. The mock logs its args
# to a file so each check can assert exactly what would have been posted.
# ---------------------------------------------------------------------------
s11() {
	local rs="${LIB}/reply-skip.sh"
	if [ ! -x "$rs" ]; then
		fail "S11: reply-skip.sh not executable"
		return
	fi

	local errors=0 code calls_log

	# 1. Inline source -> posts a reply to the correct thread
	calls_log="${TMP}/s11-calls-1.log"
	: >"$calls_log"
	local mock_ok="${TMP}/mock-gh-ok.sh"
	cat >"$mock_ok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALLS_LOG:?}"
exit 0
EOF
	chmod +x "$mock_ok"
	if CALLS_LOG="$calls_log" REPLY_SKIP_GH="$mock_ok" bash "$rs" "owner/repo" 5 "PR-5-3540349623" "pr-inline" 2 "nitpick: stylistic only" >/dev/null 2>&1; then
		if ! grep -q 'repos/owner/repo/pulls/5/comments/3540349623/replies' "$calls_log"; then
			printf '  FAIL S11.1: expected reply endpoint with comment id 3540349623 in gh call\n'
			errors=$((errors + 1))
		fi
		if ! grep -q -- '--method POST' "$calls_log"; then
			printf '  FAIL S11.1: expected --method POST in gh call\n'
			errors=$((errors + 1))
		fi
		if ! grep -q 'nitpick: stylistic only' "$calls_log"; then
			printf '  FAIL S11.1: expected rationale text in posted body\n'
			errors=$((errors + 1))
		fi
	else
		printf '  FAIL S11.1: expected exit 0 for pr-inline source, got %s\n' "$?"
		errors=$((errors + 1))
	fi

	# 2. Summary source -> no-op, gh is never invoked
	calls_log="${TMP}/s11-calls-2.log"
	rm -f "$calls_log"
	if CALLS_LOG="$calls_log" REPLY_SKIP_GH="$mock_ok" bash "$rs" "owner/repo" 5 "PR-5-4910018180" "pr-summary" 2 "walkthrough comment" >/dev/null 2>&1; then
		printf '  FAIL S11.2: expected exit 10 (no-op) for pr-summary source, got 0\n'
		errors=$((errors + 1))
	else
		code=$?
		if [ "$code" -ne 10 ]; then
			printf '  FAIL S11.2: expected exit 10 (no-op) for pr-summary source, got %s\n' "$code"
			errors=$((errors + 1))
		fi
	fi
	if [ -s "$calls_log" ] || [ -f "$calls_log" ]; then
		printf '  FAIL S11.2: gh mock was invoked for a pr-summary source; it must never be called\n'
		errors=$((errors + 1))
	fi

	# 3. Malformed finding id -> exit 1, reason on stderr
	local err
	if err=$(REPLY_SKIP_GH="$mock_ok" bash "$rs" "owner/repo" 5 "not-a-valid-id" "pr-inline" 2 "rationale" 2>&1 1>/dev/null); then
		printf '  FAIL S11.3: expected exit 1 (bad id), got 0\n'
		errors=$((errors + 1))
	else
		code=$?
		if [ "$code" -ne 1 ]; then
			printf '  FAIL S11.3: expected exit 1 (bad id), got %s\n' "$code"
			errors=$((errors + 1))
		elif ! printf '%s' "$err" | grep -q 'reply-skip:bad-id'; then
			printf '  FAIL S11.3: expected stderr reason reply-skip:bad-id\n'
			errors=$((errors + 1))
		fi
	fi

	# 4. gh POST fails -> exit 2, reason on stderr
	local mock_fail="${TMP}/mock-gh-fail.sh"
	cat >"$mock_fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$mock_fail"
	if err=$(REPLY_SKIP_GH="$mock_fail" bash "$rs" "owner/repo" 5 "PR-5-3540349623" "pr-inline" 2 "rationale" 2>&1 1>/dev/null); then
		printf '  FAIL S11.4: expected exit 2 (post failed), got 0\n'
		errors=$((errors + 1))
	else
		code=$?
		if [ "$code" -ne 2 ]; then
			printf '  FAIL S11.4: expected exit 2 (post failed), got %s\n' "$code"
			errors=$((errors + 1))
		elif ! printf '%s' "$err" | grep -q 'reply-skip:post-failed'; then
			printf '  FAIL S11.4: expected stderr reason reply-skip:post-failed\n'
			errors=$((errors + 1))
		fi
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S11: reply-skip.sh (inline posts, summary no-op, bad id, gh failure)"
	else
		fail "S11: reply-skip.sh (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S12: fetch-thread-state.sh GraphQL flattening + failure path.
# Fully offline: THREAD_STATE_GH injects a mock in place of the real gh CLI
# (same seam pattern as S11's REPLY_SKIP_GH). The mock prints a canned GraphQL
# response document, so every assertion is against deterministic fixture data.
# ---------------------------------------------------------------------------
s12() {
	local fts="${LIB}/fetch-thread-state.sh"
	local fixture="${FIXTURES}/thread-state/response.json"
	if [ ! -x "$fts" ]; then
		fail "S12: fetch-thread-state.sh not executable"
		return
	fi

	local errors=0 out="${TMP}/thread-state.json" err code

	local mock_gh="${TMP}/mock-gh-graphql.sh"
	cat >"$mock_gh" <<EOF
#!/usr/bin/env bash
cat "$fixture"
exit 0
EOF
	chmod +x "$mock_gh"

	code=0
	THREAD_STATE_GH="$mock_gh" bash "$fts" "owner/repo" 5 "$out" >/dev/null 2>&1 || code=$?
	if [ "$code" -ne 0 ]; then
		fail "S12: expected exit 0 with fixture response, got ${code}"
		return
	fi

	# 1. Comment in a resolved thread -> is_resolved true
	local resolved
	resolved=$(jq -r '.[] | select(.comment_id == 1001) | .is_resolved' "$out")
	if [ "$resolved" != "true" ]; then
		printf '  FAIL S12.1: expected comment 1001 is_resolved=true, got %s\n' "$resolved"
		errors=$((errors + 1))
	fi

	# 2. Comment in an unresolved, non-outdated thread -> both flags false;
	#    threads with no CodeRabbit comment are excluded entirely
	local unresolved_flags non_cr
	unresolved_flags=$(jq -r '.[] | select(.comment_id == 1002) | "\(.is_resolved) \(.is_outdated)"' "$out")
	if [ "$unresolved_flags" != "false false" ]; then
		printf '  FAIL S12.2: expected comment 1002 flags "false false", got "%s"\n' "$unresolved_flags"
		errors=$((errors + 1))
	fi
	non_cr=$(jq -r '[.[] | select(.comment_id == 9001)] | length' "$out")
	if [ "$non_cr" != "0" ]; then
		printf '  FAIL S12.2: comment 9001 (non-CodeRabbit thread) must be excluded\n'
		errors=$((errors + 1))
	fi

	# 3. Outdated thread -> is_outdated true on the root AND on the reply
	local outdated_count
	outdated_count=$(jq -r '[.[] | select((.comment_id == 1003 or .comment_id == 1004) and .is_outdated == true)] | length' "$out")
	if [ "$outdated_count" != "2" ]; then
		printf '  FAIL S12.3: expected comments 1003 and 1004 both is_outdated=true, got %s of 2\n' "$outdated_count"
		errors=$((errors + 1))
	fi

	# 4. gh failure -> exit 2, reason on stderr
	local mock_fail="${TMP}/mock-gh-graphql-fail.sh"
	cat >"$mock_fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$mock_fail"
	if err=$(THREAD_STATE_GH="$mock_fail" bash "$fts" "owner/repo" 5 "${TMP}/unused.json" 2>&1 1>/dev/null); then
		printf '  FAIL S12.4: expected exit 2 (fetch failed), got 0\n'
		errors=$((errors + 1))
	else
		code=$?
		if [ "$code" -ne 2 ]; then
			printf '  FAIL S12.4: expected exit 2 (fetch failed), got %s\n' "$code"
			errors=$((errors + 1))
		elif ! printf '%s' "$err" | grep -q 'thread-state:fetch-failed'; then
			printf '  FAIL S12.4: expected stderr reason thread-state:fetch-failed\n'
			errors=$((errors + 1))
		fi
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S12: fetch-thread-state.sh (resolved, unresolved, outdated+reply, fetch failure)"
	else
		fail "S12: fetch-thread-state.sh (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S13: branch-guard.sh -- passes on named non-main branches, hard-stops on
# main, master, and detached HEAD.
# ---------------------------------------------------------------------------
s13() {
	local guard="${LIB}/branch-guard.sh"
	local repo="${TMP}/s13-repo"
	local errors=0

	rm -rf "$repo"
	mkdir -p "$repo"
	(
		cd "$repo"
		git init -q
		git config user.email "smoke@rabbit-sweep.test"
		git config user.name "rabbit-sweep smoke"
		git commit -q --allow-empty -m init
	)

	# Checkout a branch by name, creating it from the current HEAD only if it
	# doesn't already exist (git's own default-branch name varies by config).
	checkout_or_create() {
		if git -C "$repo" show-ref --verify --quiet "refs/heads/$1"; then
			git -C "$repo" checkout -q "$1"
		else
			git -C "$repo" checkout -q -b "$1"
		fi
	}

	# 1. claude-feat/x -> pass, prints branch name
	checkout_or_create claude-feat/x
	local out
	if ! out=$(cd "$repo" && bash "$guard" 2>/dev/null); then
		printf '  FAIL S13.1: expected pass on claude-feat/x, guard exited non-zero\n'
		errors=$((errors + 1))
	elif [ "$out" != "claude-feat/x" ]; then
		printf '  FAIL S13.1: expected stdout "claude-feat/x", got "%s"\n' "$out"
		errors=$((errors + 1))
	fi

	# 2. feat/x (user feature branch) -> pass
	checkout_or_create feat/x
	if ! (cd "$repo" && bash "$guard" >/dev/null 2>&1); then
		printf '  FAIL S13.2: expected pass on feat/x, guard exited non-zero\n'
		errors=$((errors + 1))
	fi

	# 3. main -> hard stop
	checkout_or_create main
	if (cd "$repo" && bash "$guard" >/dev/null 2>&1); then
		printf '  FAIL S13.3: expected hard stop on main, guard exited 0\n'
		errors=$((errors + 1))
	fi

	# 4. master -> hard stop
	checkout_or_create master
	if (cd "$repo" && bash "$guard" >/dev/null 2>&1); then
		printf '  FAIL S13.4: expected hard stop on master, guard exited 0\n'
		errors=$((errors + 1))
	fi

	# 5. detached HEAD -> hard stop
	local sha
	sha=$(cd "$repo" && git rev-parse HEAD)
	(cd "$repo" && git checkout -q "$sha")
	if (cd "$repo" && bash "$guard" >/dev/null 2>&1); then
		printf '  FAIL S13.5: expected hard stop on detached HEAD, guard exited 0\n'
		errors=$((errors + 1))
	fi

	rm -rf "$repo"

	if [ "$errors" -eq 0 ]; then
		pass "S13: branch-guard.sh (claude-feat/x, feat/x pass; main, master, detached HEAD hard-stop)"
	else
		fail "S13: branch-guard.sh (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S14: detect-tests.sh -- run-all.sh and Makefile short-circuit detection;
# non-package testthat dir; existing three detections stay green; empty dir
# yields "none".
# ---------------------------------------------------------------------------
s14() {
	local detect="${LIB}/detect-tests.sh"
	local errors=0
	local d out

	# 1. tests/run-all.sh -> exactly that command, nothing else
	d="${TMP}/s14-runall"
	rm -rf "$d"
	mkdir -p "$d/tests"
	printf '#!/usr/bin/env bash\n' >"$d/tests/run-all.sh"
	out=$(bash "$detect" "$d")
	if [ "$out" != "bash tests/run-all.sh" ]; then
		printf '  FAIL S14.1: expected only "bash tests/run-all.sh", got:\n%s\n' "$out"
		errors=$((errors + 1))
	fi

	# 2. Makefile with a test: target -> "make test"
	d="${TMP}/s14-makefile"
	rm -rf "$d"
	mkdir -p "$d"
	printf 'test:\n\tpytest\n' >"$d/Makefile"
	out=$(bash "$detect" "$d")
	if [ "$out" != "make test" ]; then
		printf '  FAIL S14.2: expected only "make test", got:\n%s\n' "$out"
		errors=$((errors + 1))
	fi

	# 3. tests/testthat/ without DESCRIPTION (non-package R layout)
	d="${TMP}/s14-testthat"
	rm -rf "$d"
	mkdir -p "$d/tests/testthat"
	out=$(bash "$detect" "$d")
	if [ "$out" != "Rscript --no-init-file -e \"testthat::test_dir('tests/testthat')\"" ]; then
		printf '  FAIL S14.3: expected the testthat::test_dir command, got:\n%s\n' "$out"
		errors=$((errors + 1))
	fi

	# 4. Empty dir -> "none", exit 0
	d="${TMP}/s14-empty"
	rm -rf "$d"
	mkdir -p "$d"
	if ! out=$(bash "$detect" "$d"); then
		printf '  FAIL S14.4: expected exit 0 on an empty dir\n'
		errors=$((errors + 1))
	elif [ "$out" != "none" ]; then
		printf '  FAIL S14.4: expected "none", got:\n%s\n' "$out"
		errors=$((errors + 1))
	fi

	# 5. Kept-green: existing three detections still work.
	d="${TMP}/s14-pytest"
	rm -rf "$d"
	mkdir -p "$d/tests"
	: >"$d/pyproject.toml"
	: >"$d/uv.lock"
	out=$(bash "$detect" "$d")
	if [ "$out" != "uv run pytest" ]; then
		printf '  FAIL S14.5a: expected "uv run pytest", got:\n%s\n' "$out"
		errors=$((errors + 1))
	fi

	d="${TMP}/s14-rpkg"
	rm -rf "$d"
	mkdir -p "$d/tests"
	: >"$d/DESCRIPTION"
	out=$(bash "$detect" "$d")
	if [ "$out" != 'Rscript --no-init-file -e "devtools::test()"' ]; then
		printf '  FAIL S14.5b: expected the devtools::test command, got:\n%s\n' "$out"
		errors=$((errors + 1))
	fi

	d="${TMP}/s14-node"
	rm -rf "$d"
	mkdir -p "$d"
	printf '{"scripts":{"test":"jest"}}\n' >"$d/package.json"
	out=$(bash "$detect" "$d")
	if [ "$out" != "npm test" ]; then
		printf '  FAIL S14.5c: expected "npm test", got:\n%s\n' "$out"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S14: detect-tests.sh (run-all + Makefile short-circuit, testthat, none, kept-green pytest/R/node)"
	else
		fail "S14: detect-tests.sh (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S15: ledger persistence across separate shell processes -- pointer file +
# ledger_resume + _ledger_require guard, plus legacy-dir migration continuity.
# ---------------------------------------------------------------------------
s15() {
	local errors=0
	local test_dir="${TMP}/s15"
	rm -rf "$test_dir"
	mkdir -p "$test_dir"
	local branch="s15-branch"
	local ab_home="${TMP}/s15-home-ab"
	rm -rf "$ab_home"
	mkdir -p "$ab_home"

	# (a) init in one process, resume + append in a second -- one ledger file,
	# both events present. Exit codes are captured, not asserted here (the
	# ledger_count/event_count checks below are the actual assertions); this
	# only keeps a subprocess failure from tripping this script's own `set -e`.
	if ! HOME="$ab_home" bash -c "
		source '${LIB}/ledger.sh'
		LEDGER_DIR='${test_dir}'
		ledger_init '${branch}' 'main' 'local' >/dev/null
	"; then
		printf '  FAIL S15.1: ledger_init subprocess exited non-zero\n'
		errors=$((errors + 1))
	fi
	if ! HOME="$ab_home" bash -c "
		source '${LIB}/ledger.sh'
		LEDGER_DIR='${test_dir}'
		ledger_resume '${branch}' && ledger_skip 'S15-1' 2 'nitpick'
	"; then
		printf '  FAIL S15.1: ledger_resume + ledger_skip subprocess exited non-zero\n'
		errors=$((errors + 1))
	fi

	local ledger_count
	ledger_count=$(find "$test_dir" -maxdepth 1 -name '*.jsonl' | wc -l | tr -d ' ')
	if [ "$ledger_count" -ne 1 ]; then
		printf '  FAIL S15.1: expected exactly 1 ledger file across both processes, found %s\n' "$ledger_count"
		errors=$((errors + 1))
	else
		local f event_count
		f=$(find "$test_dir" -maxdepth 1 -name '*.jsonl')
		event_count=$(wc -l <"$f" | tr -d ' ')
		if [ "$event_count" -ne 2 ]; then
			printf '  FAIL S15.1: expected 2 events (review_started + skip) in the one ledger, got %s\n' "$event_count"
			errors=$((errors + 1))
		fi
	fi

	# (b) a mutator with $LEDGER unset (no ledger_resume call) fails non-zero
	# and points at ledger_resume rather than blind-appending.
	local err
	if err=$(HOME="$ab_home" env -u LEDGER bash -c "source '${LIB}/ledger.sh'; ledger_skip 'S15-2' 2 'no ledger set'" 2>&1); then
		printf '  FAIL S15.2: expected ledger_skip to fail with no $LEDGER set, but it succeeded\n'
		errors=$((errors + 1))
	elif ! printf '%s' "$err" | grep -q 'ledger_resume'; then
		printf '  FAIL S15.2: expected the failure message to mention ledger_resume, got: %s\n' "$err"
		errors=$((errors + 1))
	fi

	# (c) one-time legacy-dir migration: a staged pre-rename run directory
	# moves once, and ledger_handled_ids still returns its pre-rename ids.
	local fake_home="${TMP}/s15-fakehome"
	rm -rf "$fake_home"
	mkdir -p "${fake_home}/.claude/anaiis-coderabbit/runs"
	printf '{"event":"intent_verified","id":"PR-77-501"}\n' >"${fake_home}/.claude/anaiis-coderabbit/runs/legacy.jsonl"

	local handled
	handled=$(HOME="$fake_home" bash -c "source '${LIB}/ledger.sh'; ledger_handled_ids 77")

	if [ ! -d "${fake_home}/.claude/rabbit-sweep" ]; then
		printf '  FAIL S15.3: expected the legacy run directory to migrate to .claude/rabbit-sweep\n'
		errors=$((errors + 1))
	fi
	if [ -d "${fake_home}/.claude/anaiis-coderabbit" ]; then
		printf '  FAIL S15.3: expected the legacy directory to no longer exist after migration\n'
		errors=$((errors + 1))
	fi
	if ! printf '%s\n' "$handled" | grep -qxF "PR-77-501"; then
		printf '  FAIL S15.3: expected ledger_handled_ids to still return pre-rename id PR-77-501, got: %s\n' "$handled"
		errors=$((errors + 1))
	fi
	rm -rf "$fake_home"

	# (d) ledger_no_tests writes a distinct, queryable event.
	local no_tests_ledger="${TMP}/s15-no-tests.jsonl"
	local d_home="${TMP}/s15-home-d"
	rm -rf "$d_home"
	mkdir -p "$d_home"
	local old_home="$HOME"
	HOME="$d_home"
	LEDGER="$no_tests_ledger"
	: >"$LEDGER"
	# shellcheck source=lib/ledger.sh
	source "${LIB}/ledger.sh"
	LEDGER_DIR="$test_dir"
	if ! ledger_no_tests "S15-4" 2>/dev/null; then
		printf '  FAIL S15.4: ledger_no_tests exited non-zero or is not defined\n'
		errors=$((errors + 1))
	fi
	if ! grep -q '"event":"no_tests","id":"S15-4"' "$no_tests_ledger"; then
		printf '  FAIL S15.4: expected a no_tests event for S15-4, got:\n%s\n' "$(cat "$no_tests_ledger")"
		errors=$((errors + 1))
	fi
	HOME="$old_home"

	if [ "$errors" -eq 0 ]; then
		pass "S15: ledger persistence (cross-process resume, unset-LEDGER guard, legacy migration continuity, no_tests event)"
	else
		fail "S15: ledger persistence (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S16: dispatch reconciliation -- ledger_surgeon_dispatched / ledger_undispatched_fixes
# catch a decision:"fix" with no matching surgeon dispatch (A4), and
# ledger_sweep_ran records the reconciliation sweep for audit.
# ---------------------------------------------------------------------------
s16() {
	local ledger="${TMP}/s16.jsonl"
	export LEDGER="$ledger"
	# shellcheck source=lib/ledger.sh
	source "${LIB}/ledger.sh"
	LEDGER_DIR="$TMP"
	: >"$ledger"

	local errors=0

	ledger_decision "CLI-1" 4 "fix" "severity 4: fix without triage" true
	ledger_decision "CLI-2" 4 "fix" "severity 4: fix without triage" true
	ledger_surgeon_dispatched "CLI-2"

	local undispatched
	undispatched=$(ledger_undispatched_fixes)
	if [ "$undispatched" != "CLI-1" ]; then
		printf '  FAIL S16.1: expected only CLI-1 undispatched, got: %s\n' "$undispatched"
		errors=$((errors + 1))
	fi

	ledger_surgeon_dispatched "CLI-1"
	undispatched=$(ledger_undispatched_fixes)
	if [ -n "$undispatched" ]; then
		printf '  FAIL S16.2: expected no undispatched fixes after dispatching CLI-1, got: %s\n' "$undispatched"
		errors=$((errors + 1))
	fi

	ledger_sweep_ran 1
	if ! grep -q '"event":"sweep_ran","count":1' "$ledger"; then
		printf '  FAIL S16.3: expected a sweep_ran event with count 1\n'
		errors=$((errors + 1))
	fi

	undispatched=$(ledger_undispatched_fixes)
	if [ -z "$undispatched" ]; then
		ledger_sweep_ran 0
		if ! grep -q '"event":"sweep_ran","count":0' "$ledger"; then
			printf '  FAIL S16.4: expected a sweep_ran event with count 0 for clean sweep\n'
			errors=$((errors + 1))
		fi
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S16: dispatch reconciliation (undispatched-fix detection, sweep audit event)"
	else
		fail "S16: dispatch reconciliation (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S17: round-scoped ledger ids (A5) -- the same CodeRabbit id reused across two
# rounds becomes two distinct, auditable ledger ids. Structural check confirms
# phases.md carries the rewrite in both Phase 3 and Phase 7 (local mode only);
# the correctness fixture proves the pattern itself is sound and that PR-mode
# ids (never touched by this rewrite) still resolve through ledger_handled_ids.
# ---------------------------------------------------------------------------
s17() {
	local errors=0
	local phases="${SKILL_ROOT}/references/phases.md"
	local scope_pattern='"R" + ($round|tostring) + "-" + .id'

	local scope_count
	scope_count=$(grep -cF "$scope_pattern" "$phases" 2>/dev/null) || scope_count=0
	if [ "$scope_count" -lt 2 ]; then
		printf '  FAIL S17.1: expected the round-scoping id rewrite in both Phase 3 and Phase 7 of phases.md, found %s occurrence(s)\n' "$scope_count"
		errors=$((errors + 1))
	fi
	if ! grep -q "local-mode only\|Local mode only" "$phases" 2>/dev/null; then
		printf '  FAIL S17.2: phases.md missing an explicit local-mode-only note near the id rewrite\n'
		errors=$((errors + 1))
	fi

	# Correctness fixture: the same restarting CodeRabbit id across two rounds.
	local round1="${TMP}/s17-round1.ndjson"
	printf '{"id":"CLI-1","file":"a.R","severity":4}\n' >"$round1"
	jq -c --argjson round 1 '.id = ("R" + ($round|tostring) + "-" + .id)' "$round1" \
		>"${round1}.scoped"

	local round2="${TMP}/s17-round2.ndjson"
	printf '{"id":"CLI-1","file":"b.R","severity":3}\n' >"$round2"
	jq -c --argjson round 2 '.id = ("R" + ($round|tostring) + "-" + .id)' "$round2" \
		>"${round2}.scoped"

	local id1 id2
	id1=$(jq -r '.id' "${round1}.scoped")
	id2=$(jq -r '.id' "${round2}.scoped")

	if [ "$id1" != "R1-CLI-1" ]; then
		printf '  FAIL S17.3: expected round 1 id R1-CLI-1, got %s\n' "$id1"
		errors=$((errors + 1))
	fi
	if [ "$id2" != "R2-CLI-1" ]; then
		printf '  FAIL S17.3: expected round 2 id R2-CLI-1, got %s\n' "$id2"
		errors=$((errors + 1))
	fi
	if [ "$id1" = "$id2" ]; then
		printf '  FAIL S17.4: round 1 and round 2 ids collided after scoping: %s\n' "$id1"
		errors=$((errors + 1))
	fi

	# Feed both scoped ids through the ledger and confirm they are distinct, auditable entries.
	local ledger="${TMP}/s17.jsonl"
	export LEDGER="$ledger"
	# shellcheck source=lib/ledger.sh
	source "${LIB}/ledger.sh"
	LEDGER_DIR="$TMP"
	: >"$ledger"
	ledger_decision "$id1" 4 "fix" "round 1 finding" true
	ledger_decision "$id2" 3 "fix" "round 2 finding" true

	local unique_ids
	unique_ids=$(jq -r 'select(.event=="decision") | .id' "$ledger" | sort -u | wc -l | tr -d ' ')
	if [ "$unique_ids" -ne 2 ]; then
		printf '  FAIL S17.5: expected 2 distinct decision ids in the ledger, got %s\n' "$unique_ids"
		errors=$((errors + 1))
	fi

	# PR-mode regression guard: this rewrite must never run in PR mode, and
	# ledger_handled_ids' PR-id matching must still work unaffected by it.
	: >"$ledger"
	printf '{"event":"intent_verified","id":"PR-77-501"}\n' >>"$ledger"
	local handled
	handled=$(ledger_handled_ids 77)
	if ! printf '%s\n' "$handled" | grep -qxF "PR-77-501"; then
		printf '  FAIL S17.6: PR-mode id PR-77-501 no longer resolves through ledger_handled_ids\n'
		errors=$((errors + 1))
	fi

	rm -f "${round1}.scoped" "${round2}.scoped"

	if [ "$errors" -eq 0 ]; then
		pass "S17: round-scoped ledger ids (distinct across rounds, PR-mode ids unaffected)"
	else
		fail "S17: round-scoped ledger ids (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S18: fingerprint + prior-verdict short-circuit (A6) -- a repeat sev-3+
# finding (same file + suggestion, different round/id) resolves from a prior
# **skip** verdict without a fresh triage spawn. A prior "fix" verdict is
# never reused this way (see phases.md Phase 4): a fixture below asserts the
# reuse condition rejects a "fix" verdict, and the skip-only restriction is
# also checked structurally, scoped to the Phase 4 section.
# ---------------------------------------------------------------------------
s18() {
	local errors=0
	local ledger="${TMP}/s18.jsonl"
	export LEDGER="$ledger"
	# shellcheck source=lib/ledger.sh
	source "${LIB}/ledger.sh"
	LEDGER_DIR="$TMP"
	: >"$ledger"

	local fp
	fp=$(ledger_fingerprint "runs.yaml" "add speculative max_num_rows field")

	# Round 1: CLI-9 rejects the speculative field.
	ledger_decision "R1-CLI-9" 4 "skip" "no consumer exists" "" "$fp"

	if ! grep -q "\"fingerprint\":\"${fp}\"" "$ledger"; then
		printf '  FAIL S18.1: expected the decision event to carry fingerprint %s\n' "$fp"
		errors=$((errors + 1))
	fi

	# Round 2: the same substantive question resurfaces under a different id.
	local verdict
	verdict=$(ledger_prior_verdict "$fp")
	if [ -z "$verdict" ]; then
		printf '  FAIL S18.2: expected a prior verdict for fingerprint %s, got none\n' "$fp"
		errors=$((errors + 1))
	else
		local prior_decision prior_id
		prior_decision=$(printf '%s' "$verdict" | jq -r '.decision')
		prior_id=$(printf '%s' "$verdict" | jq -r '.id')
		if [ "$prior_decision" != "skip" ]; then
			printf '  FAIL S18.3: expected prior decision "skip", got %s\n' "$prior_decision"
			errors=$((errors + 1))
		fi
		if [ "$prior_id" != "R1-CLI-9" ]; then
			printf '  FAIL S18.4: expected prior id R1-CLI-9, got %s\n' "$prior_id"
			errors=$((errors + 1))
		fi
	fi

	# A different fingerprint (no prior history) must return nothing.
	local no_prior
	no_prior=$(ledger_prior_verdict "0000000000000000000000000000000000000000")
	if [ -n "$no_prior" ]; then
		printf '  FAIL S18.5: expected no prior verdict for an unseen fingerprint, got: %s\n' "$no_prior"
		errors=$((errors + 1))
	fi

	# A prior "fix" verdict for a fingerprint must be rejected by the reuse
	# condition: ledger_prior_verdict surfaces it plainly, and the documented
	# short-circuit condition (.decision == "skip") must evaluate false for it.
	local fp_fix
	fp_fix=$(ledger_fingerprint "other.yaml" "add another speculative field")
	ledger_decision "R1-CLI-10" 3 "fix" "needed after all" true "$fp_fix"

	local fix_verdict
	fix_verdict=$(ledger_prior_verdict "$fp_fix")
	if [ -z "$fix_verdict" ]; then
		printf '  FAIL S18.6: expected a prior verdict for fingerprint %s, got none\n' "$fp_fix"
		errors=$((errors + 1))
	else
		local fix_prior_decision
		fix_prior_decision=$(printf '%s' "$fix_verdict" | jq -r '.decision')
		if [ "$fix_prior_decision" != "fix" ]; then
			printf '  FAIL S18.7: expected prior decision "fix", got %s\n' "$fix_prior_decision"
			errors=$((errors + 1))
		fi
		if [ "$fix_prior_decision" = "skip" ]; then
			printf '  FAIL S18.8: fingerprint reuse condition incorrectly accepted a "fix" verdict as reusable\n'
			errors=$((errors + 1))
		fi
	fi

	# A repeat sev-3+ finding whose fingerprint matches a prior skip, but whose
	# target file's content hash differs from what was recorded with that
	# decision (e.g. a later fix touched the same file), must not be reused --
	# the caller falls through to coderabbit-triage instead of short-circuiting.
	local fp_hash
	fp_hash=$(ledger_fingerprint "hashed.yaml" "same finding text, file content changed later")
	ledger_decision "R1-CLI-11" 3 "skip" "no consumer exists" "" "$fp_hash" "hash_v1"

	local hash_verdict
	hash_verdict=$(ledger_prior_verdict "$fp_hash")
	if [ -z "$hash_verdict" ]; then
		printf '  FAIL S18.11: expected a prior verdict for fingerprint %s, got none\n' "$fp_hash"
		errors=$((errors + 1))
	else
		local prior_file_hash current_hash
		prior_file_hash=$(printf '%s' "$hash_verdict" | jq -r '.file_hash // empty')
		if [ "$prior_file_hash" != "hash_v1" ]; then
			printf '  FAIL S18.12: expected prior file_hash "hash_v1", got %s\n' "$prior_file_hash"
			errors=$((errors + 1))
		fi
		# Simulate the target file's content having changed since the skip was recorded.
		current_hash="hash_v2"
		if [ "$current_hash" = "$prior_file_hash" ]; then
			printf '  FAIL S18.13: current file hash unexpectedly matched a deliberately different prior hash -- reuse would be incorrectly accepted\n'
			errors=$((errors + 1))
		fi
	fi

	# Structural: Phase 4 (scoped to its own section) must restrict the
	# short-circuit to prior "skip" verdicts only.
	local phases="${SKILL_ROOT}/references/phases.md"
	local phase4_section
	phase4_section=$(awk '/^## Phase 4/{flag=1; next} /^## Phase [0-9]/{if (flag) exit} flag' "$phases" 2>/dev/null)
	if ! printf '%s' "$phase4_section" | grep -qi 'prior skip\|skip verdict'; then
		printf '  FAIL S18.9: Phase 4 section missing a skip-only restriction near the fingerprint short-circuit\n'
		errors=$((errors + 1))
	fi
	if ! printf '%s' "$phase4_section" | grep -q 'ledger_prior_verdict'; then
		printf '  FAIL S18.10: Phase 4 section does not reference ledger_prior_verdict\n'
		errors=$((errors + 1))
	fi
	if ! printf '%s' "$phase4_section" | grep -qi 'file_hash\|hash_object'; then
		printf '  FAIL S18.14: Phase 4 section missing a file-content-hash check gating skip reuse\n'
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S18: fingerprint short-circuit (prior skip verdict reused, unseen fingerprint empty)"
	else
		fail "S18: fingerprint short-circuit (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S19: replay-corpus.sh -- synthetic corpus under isolated roots (never touches
# real ~/.coderabbit or ~/.claude/rabbit-sweep). A planted round-2 finding on
# the same file+line as a round-1 finding must be detected as a re-flag; round
# 1 itself (no prior round to compare against) must always report zero. A
# session with an unresolvable HEAD must be skipped with a reason, never
# silently dropped.
# ---------------------------------------------------------------------------
s19() {
	local replay="${LIB}/replay-corpus.sh"
	local errors=0

	local repo="${TMP}/s19-repo"
	rm -rf "$repo"
	mkdir -p "$repo"
	(
		cd "$repo"
		git init -q
		git config user.email "smoke@rabbit-sweep.test"
		git config user.name "rabbit-sweep smoke"
		git commit -q --allow-empty -m c0
	)
	local c0 c1 c2
	c0=$(git -C "$repo" rev-parse HEAD)
	(cd "$repo" && git commit -q --allow-empty -m c1)
	c1=$(git -C "$repo" rev-parse HEAD)
	(cd "$repo" && git commit -q --allow-empty -m c2)
	c2=$(git -C "$repo" rev-parse HEAD)

	local reviews_root="${TMP}/s19-reviews" ledger_root="${TMP}/s19-ledgers" out_dir="${TMP}/s19-out"
	rm -rf "$reviews_root" "$ledger_root" "$out_dir"
	mkdir -p "${reviews_root}/repoA/branchA/reviews/1000" "${reviews_root}/repoA/branchA/reviews/2000"
	mkdir -p "${reviews_root}/repoB/branchB/reviews/1000"
	mkdir -p "$ledger_root"

	# Real, current-time-relative epochs so find_ledger_for_branch's date math
	# (which compares a ledger's own start time against the review session's)
	# has a realistic ledger-started-before-session ordering to check.
	local now_s now_ms ledger_ts round1_epoch round2_epoch
	now_s=$(date -u +%s)
	now_ms=$((now_s * 1000))
	ledger_ts=$(date -u -j -f '%s' "$((now_s - 600))" +%Y%m%dT%H%M%SZ 2>/dev/null \
		|| date -u -d "@$((now_s - 600))" +%Y%m%dT%H%M%SZ)
	round1_epoch=$((now_ms - 500000))
	round2_epoch=$((now_ms - 400000))

	# Round 1: base=c0, head=c1, findings on a.txt at lines 5 and 50.
	jq -n --arg base "$c0" --arg head "$c1" --arg branch "test-branch" --arg wd "$repo" \
		'{baseBranch:"main", baseCommitId:$base, currentBranch:$branch, head:$head, workingDirectory:$wd, diff:[], timestamp:1000}' \
		>"${reviews_root}/repoA/branchA/reviews/1000/git.json"
	printf '{}' >"${reviews_root}/repoA/branchA/reviews/1000/internalState.json"
	jq -n '{fileName:"a.txt", startLine:5, endLine:5, severity:"major", id:"f1", title:"restrict via policy prose"}' \
		>"${reviews_root}/repoA/branchA/reviews/1000/11111111-1111-1111-1111-111111111111.json"
	jq -n '{fileName:"a.txt", startLine:50, endLine:50, severity:"major", id:"f2"}' \
		>"${reviews_root}/repoA/branchA/reviews/1000/22222222-2222-2222-2222-222222222222.json"

	# Round 2: base=c1, head=c2. One finding planted on the SAME file+line as
	# round 1's f1 (a re-flag); one on a new, unrelated line (not a re-flag).
	jq -n --arg base "$c1" --arg head "$c2" --arg branch "test-branch" --arg wd "$repo" \
		'{baseBranch:"main", baseCommitId:$base, currentBranch:$branch, head:$head, workingDirectory:$wd, diff:[], timestamp:2000}' \
		>"${reviews_root}/repoA/branchA/reviews/2000/git.json"
	printf '{}' >"${reviews_root}/repoA/branchA/reviews/2000/internalState.json"
	jq -n '{fileName:"a.txt", startLine:5, endLine:5, severity:"major", id:"f3", title:"remove Bash entirely instead"}' \
		>"${reviews_root}/repoA/branchA/reviews/2000/33333333-3333-3333-3333-333333333333.json"
	jq -n '{fileName:"b.txt", startLine:99, endLine:99, severity:"major", id:"f4"}' \
		>"${reviews_root}/repoA/branchA/reviews/2000/44444444-4444-4444-4444-444444444444.json"

	# Skipped session: workingDirectory resolves, but head does not.
	jq -n --arg base "$c0" --arg wd "$repo" \
		'{baseBranch:"main", baseCommitId:$base, currentBranch:"branchB", head:"0000000000000000000000000000000000000000", workingDirectory:$wd, diff:[], timestamp:1000}' \
		>"${reviews_root}/repoB/branchB/reviews/1000/git.json"
	printf '{}' >"${reviews_root}/repoB/branchB/reviews/1000/internalState.json"

	# Hand-written ledger (not via ledger_init, so ts can be backdated deterministically).
	local ledger_file="${ledger_root}/test-branch-fixture.jsonl"
	{
		printf '{"event":"review_started","branch":"test-branch","base":"main","mode":"local","ts":"%s"}\n' "$ledger_ts"
		printf '{"event":"round_start","round":1}\n'
		printf '{"event":"decision","id":"f1","severity":4,"decision":"fix","rationale":"test","requires_verify":true}\n'
		printf '{"event":"intent_verified","id":"f1"}\n'
		printf '{"event":"decision","id":"f2","severity":4,"decision":"fix","rationale":"test","requires_verify":true}\n'
		printf '{"event":"intent_verified","id":"f2"}\n'
		printf '{"event":"round_start","round":2}\n'
		printf '{"event":"decision","id":"f3","severity":4,"decision":"fix","rationale":"test","requires_verify":true}\n'
		printf '{"event":"intent_verified","id":"f3"}\n'
	} >"$ledger_file"

	# Force the round dirs to carry the realistic epochs computed above (jq -n above used
	# placeholder timestamps only for git.json's own informational field; the round dir
	# *names* are what replay-corpus.sh actually sorts and matches against).
	mv "${reviews_root}/repoA/branchA/reviews/1000" "${reviews_root}/repoA/branchA/reviews/${round1_epoch}"
	mv "${reviews_root}/repoA/branchA/reviews/2000" "${reviews_root}/repoA/branchA/reviews/${round2_epoch}"
	mv "${reviews_root}/repoB/branchB/reviews/1000" "${reviews_root}/repoB/branchB/reviews/${round1_epoch}"

	local out
	out=$(REPLAY_REVIEWS_ROOT="$reviews_root" REPLAY_LEDGER_ROOT="$ledger_root" REPLAY_OUT_DIR="$out_dir" \
		bash "$replay" 2>&1) || {
		printf '  FAIL S19: replay-corpus.sh exited non-zero: %s\n' "$out"
		errors=$((errors + 1))
	}

	if [ -f "${out_dir}/replay-corpus.json" ]; then
		local r1_reflags r2_reflags r2_findings
		r1_reflags=$(jq -r '.[] | select(.session.branch_hash=="branchA") | .rounds[0].reflags' "${out_dir}/replay-corpus.json")
		r2_reflags=$(jq -r '.[] | select(.session.branch_hash=="branchA") | .rounds[1].reflags' "${out_dir}/replay-corpus.json")
		r2_findings=$(jq -r '.[] | select(.session.branch_hash=="branchA") | .rounds[1].findings' "${out_dir}/replay-corpus.json")

		if [ "$r1_reflags" != "0" ]; then
			printf '  FAIL S19.1: round 1 (no prior round) should report 0 reflags, got %s\n' "$r1_reflags"
			errors=$((errors + 1))
		fi
		if [ "$r2_findings" != "2" ]; then
			printf '  FAIL S19.2: round 2 should have 2 findings, got %s\n' "$r2_findings"
			errors=$((errors + 1))
		fi
		if [ "$r2_reflags" != "1" ]; then
			printf '  FAIL S19.3: round 2 should have exactly 1 reflag (the planted a.txt:5 repeat), got %s\n' "$r2_reflags"
			errors=$((errors + 1))
		fi

		local skip_reason
		skip_reason=$(jq -r '.[] | select(.session.branch_hash=="branchB") | .skip_reason' "${out_dir}/replay-corpus.json")
		if [ -z "$skip_reason" ] || [ "$skip_reason" = "null" ]; then
			printf '  FAIL S19.4: branchB (unresolvable HEAD) should be skipped with a reason, got none\n'
			errors=$((errors + 1))
		elif ! printf '%s' "$skip_reason" | grep -q "unresolvable HEAD"; then
			printf '  FAIL S19.4: expected an unresolvable-HEAD skip reason, got: %s\n' "$skip_reason"
			errors=$((errors + 1))
		fi

		# Contradiction candidates: reported separately (surfaced for human/model review),
		# never folded into reflag_count or any other deterministic rate.
		local cand_count cand_cur_title cand_prior_title
		cand_count=$(jq -r '.[] | select(.session.branch_hash=="branchA") | .rounds[1].contradiction_candidates | length' "${out_dir}/replay-corpus.json")
		if [ "$cand_count" != "1" ]; then
			printf '  FAIL S19.5: round 2 should have exactly 1 contradiction candidate, got %s\n' "$cand_count"
			errors=$((errors + 1))
		fi
		cand_cur_title=$(jq -r '.[] | select(.session.branch_hash=="branchA") | .rounds[1].contradiction_candidates[0].current.title' "${out_dir}/replay-corpus.json")
		cand_prior_title=$(jq -r '.[] | select(.session.branch_hash=="branchA") | .rounds[1].contradiction_candidates[0].prior.title' "${out_dir}/replay-corpus.json")
		if [ "$cand_cur_title" != "remove Bash entirely instead" ] || [ "$cand_prior_title" != "restrict via policy prose" ]; then
			printf '  FAIL S19.6: contradiction candidate should pair current="remove Bash entirely instead" against prior="restrict via policy prose", got current=%s prior=%s\n' \
				"$cand_cur_title" "$cand_prior_title"
			errors=$((errors + 1))
		fi
		if ! grep -q 'Contradiction candidates' "${out_dir}/replay-corpus.md"; then
			printf '  FAIL S19.7: replay-corpus.md should have a Contradiction candidates section\n'
			errors=$((errors + 1))
		fi
	else
		printf '  FAIL S19: %s was not written\n' "${out_dir}/replay-corpus.json"
		errors=$((errors + 1))
	fi

	rm -rf "$repo" "$reviews_root" "$ledger_root" "$out_dir"

	if [ "$errors" -eq 0 ]; then
		pass "S19: replay-corpus.sh (planted re-flag detected, round 1 baseline zero, unresolvable-HEAD skip reported)"
	else
		fail "S19: replay-corpus.sh (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S20: mine-agent-costs.sh -- synthetic transcripts under an isolated projects
# root (never touches real ~/.claude/projects). A duplicate tool_use id
# appearing in two files (mirroring the real 2d458711/55e484ef fork this
# session found) must be deduplicated, not double-counted. Two overlapping
# dispatches whose descriptions name the same file must be flagged as a
# same-file overlap.
# ---------------------------------------------------------------------------
s20() {
	local miner="${LIB}/mine-agent-costs.sh"
	local errors=0

	local proj_root="${TMP}/s20-projects" out_dir="${TMP}/s20-out"
	local proj_dir="${proj_root}/fake-project"
	rm -rf "$proj_root" "$out_dir"
	mkdir -p "$proj_dir"

	# Base epoch chosen arbitrarily in the past; only relative ordering matters.
	local base=1700000000
	local ts_a ts_b ts_a_ack ts_b_ack ts_a_note ts_b_note
	ts_a=$(date -u -r "$base" +"%Y-%m-%dT%H:%M:%S.000Z")
	ts_a_ack=$(date -u -r "$((base + 1))" +"%Y-%m-%dT%H:%M:%S.000Z")
	ts_b=$(date -u -r "$((base + 2))" +"%Y-%m-%dT%H:%M:%S.000Z") # dispatched before A's notification -> overlap
	ts_b_ack=$(date -u -r "$((base + 3))" +"%Y-%m-%dT%H:%M:%S.000Z")
	ts_a_note=$(date -u -r "$((base + 10))" +"%Y-%m-%dT%H:%M:%S.000Z")
	ts_b_note=$(date -u -r "$((base + 8))" +"%Y-%m-%dT%H:%M:%S.000Z")

	# session1.jsonl: call A and call B, both describing "same.sh" -- a planted same-file
	# overlap (B is dispatched at base+2, before A's notification arrives at base+10).
	{
		printf '{"message":{"content":[{"type":"tool_use","id":"toolu_AAA","name":"Agent","input":{"subagent_type":"test:agent","description":"Fix same.sh part one"}}]},"uuid":"u1","timestamp":"%s"}\n' "$ts_a"
		printf '{"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_AAA","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"timestamp":"%s"}\n' "$ts_a_ack"
		printf '{"message":{"content":[{"type":"tool_use","id":"toolu_BBB","name":"Agent","input":{"subagent_type":"test:agent","description":"Fix same.sh part two"}}]},"uuid":"u2","timestamp":"%s"}\n' "$ts_b"
		printf '{"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_BBB","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"timestamp":"%s"}\n' "$ts_b_ack"
		printf '{"message":{"content":"<task-notification>\\n<tool-use-id>toolu_BBB</tool-use-id>\\n<status>completed</status>\\n<usage><subagent_tokens>800</subagent_tokens><tool_uses>1</tool_uses><duration_ms>4000</duration_ms></usage>\\n</task-notification>"},"timestamp":"%s"}\n' "$ts_b_note"
		printf '{"message":{"content":"<task-notification>\\n<tool-use-id>toolu_AAA</tool-use-id>\\n<status>completed</status>\\n<usage><subagent_tokens>1000</subagent_tokens><tool_uses>2</tool_uses><duration_ms>5000</duration_ms></usage>\\n</task-notification>"},"timestamp":"%s"}\n' "$ts_a_note"
	} >"${proj_dir}/session1.jsonl"

	# session2.jsonl: a duplicate of call A's tool_use (same id), mirroring a forked/resumed
	# session that shares a history prefix. Must not inflate the dedup'd call count.
	printf '{"message":{"content":[{"type":"tool_use","id":"toolu_AAA","name":"Agent","input":{"subagent_type":"test:agent","description":"Fix same.sh part one"}}]},"uuid":"u1","timestamp":"%s"}\n' "$ts_a" \
		>"${proj_dir}/session2.jsonl"

	local out
	out=$(MINE_PROJECTS_ROOT="$proj_root" MINE_OUT_DIR="$out_dir" bash "$miner" --project fake-project 2>&1) || {
		printf '  FAIL S20: mine-agent-costs.sh exited non-zero: %s\n' "$out"
		errors=$((errors + 1))
	}

	if [ -f "${out_dir}/agent-costs.json" ]; then
		local total
		total=$(jq 'length' "${out_dir}/agent-costs.json")
		if [ "$total" != "2" ]; then
			printf '  FAIL S20.1: expected 2 deduplicated calls (toolu_AAA appears in 2 files), got %s\n' "$total"
			errors=$((errors + 1))
		fi

		# concurrency.json is a script-internal temp file, not a copied artifact; assert
		# through the rendered markdown table instead.
		local same
		if ! grep -q "session1.jsonl" "${out_dir}/agent-costs.md"; then
			printf '  FAIL S20.2: agent-costs.md should report concurrency for session1.jsonl\n'
			errors=$((errors + 1))
		fi
		same=$(awk -F'|' '/session1\.jsonl/ {gsub(/ /,"",$5); print $5}' "${out_dir}/agent-costs.md")
		if [ "$same" != "1" ]; then
			printf '  FAIL S20.3: expected 1 same-file overlap for session1.jsonl (planted same.sh/same.sh pair), got %s\n' "${same:-<empty>}"
			errors=$((errors + 1))
		fi
	else
		printf '  FAIL S20: %s was not written\n' "${out_dir}/agent-costs.json"
		errors=$((errors + 1))
	fi

	rm -rf "$proj_root" "$out_dir"

	if [ "$errors" -eq 0 ]; then
		pass "S20: mine-agent-costs.sh (duplicate id deduplicated, same-file overlap flagged)"
	else
		fail "S20: mine-agent-costs.sh (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S21: ledger.sh cost instrumentation -- every event carries a ts field (added
# centrally in _ledger_event, not by touching each of the 13 emitting
# functions), ledger_agent_spawn is additive alongside ledger_surgeon_dispatched
# (never replaces it -- ledger_undispatched_fixes greps event=="dispatched"
# specifically), and a pre-ts-schema ledger still parses without error.
# ---------------------------------------------------------------------------
s21() {
	local errors=0
	local ledger="${TMP}/s21.jsonl"
	export LEDGER="$ledger"
	# shellcheck source=lib/ledger.sh
	source "${LIB}/ledger.sh"
	LEDGER_DIR="$TMP"
	: >"$ledger"

	ledger_skip "CLI-1" 2 "nitpick"
	ledger_decision "CLI-2" 4 "fix" "test" true
	ledger_agent_spawn "CLI-2" "code-surgeon"
	ledger_agent_spawn "CLI-3" "intent-verifier"
	ledger_agent_spawn "CLI-4" "coderabbit-triage"

	# 1. Every event carries a non-null ts.
	local missing_ts
	missing_ts=$(jq -r 'select(.ts == null)' "$ledger" | wc -l | tr -d ' ')
	if [ "$missing_ts" -ne 0 ]; then
		printf '  FAIL S21.1: %s event(s) missing a ts field\n' "$missing_ts"
		errors=$((errors + 1))
	fi

	# 2. ts is monotonically non-decreasing across the file (append order).
	local out_of_order
	out_of_order=$(jq -rs '[.[].ts] as $ts | [range(0; ($ts|length)-1) | select($ts[.] > $ts[.+1])] | length' "$ledger")
	if [ "$out_of_order" -ne 0 ]; then
		printf '  FAIL S21.2: ts is not monotonically non-decreasing (%s inversions)\n' "$out_of_order"
		errors=$((errors + 1))
	fi

	# 3. ledger_agent_spawn events are countable per id and per agent_type.
	local spawn_count code_surgeon_count
	spawn_count=$(jq -rs '[.[] | select(.event=="agent_spawn")] | length' "$ledger")
	code_surgeon_count=$(jq -rs '[.[] | select(.event=="agent_spawn" and .agent_type=="code-surgeon")] | length' "$ledger")
	if [ "$spawn_count" -ne 3 ]; then
		printf '  FAIL S21.3: expected 3 agent_spawn events, got %s\n' "$spawn_count"
		errors=$((errors + 1))
	fi
	if [ "$code_surgeon_count" -ne 1 ]; then
		printf '  FAIL S21.3: expected 1 code-surgeon agent_spawn event, got %s\n' "$code_surgeon_count"
		errors=$((errors + 1))
	fi

	# 4. ledger_agent_spawn is additive: it must not replace or rename the "dispatched" event
	# that ledger_undispatched_fixes depends on for its reconciliation-sweep query.
	ledger_surgeon_dispatched "CLI-2"
	local undispatched
	undispatched=$(ledger_undispatched_fixes)
	if [ -n "$undispatched" ]; then
		printf '  FAIL S21.4: CLI-2 should be dispatched (ledger_surgeon_dispatched still works), got undispatched: %s\n' "$undispatched"
		errors=$((errors + 1))
	fi

	# 5. A pre-ts-schema ledger (events with no ts field at all, matching this corpus's real
	# historical ledgers) must still parse without error via existing ledger functions.
	local legacy="${TMP}/s21-legacy.jsonl"
	{
		printf '{"event":"review_started","branch":"x","base":"main","mode":"local"}\n'
		printf '{"event":"decision","id":"CLI-1","severity":4,"decision":"fix","rationale":"r","requires_verify":true}\n'
	} >"$legacy"
	LEDGER="$legacy"
	local legacy_undispatched
	if ! legacy_undispatched=$(ledger_undispatched_fixes 2>&1); then
		printf '  FAIL S21.5: ledger_undispatched_fixes should parse a pre-ts-schema ledger without error, got: %s\n' "$legacy_undispatched"
		errors=$((errors + 1))
	elif [ "$legacy_undispatched" != "CLI-1" ]; then
		printf '  FAIL S21.5: expected CLI-1 undispatched in the legacy ledger, got: %s\n' "$legacy_undispatched"
		errors=$((errors + 1))
	fi
	LEDGER="$ledger"

	if [ "$errors" -eq 0 ]; then
		pass "S21: ledger.sh cost instrumentation (monotonic ts, additive agent_spawn, legacy-schema parse)"
	else
		fail "S21: ledger.sh cost instrumentation (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# Run all
# ---------------------------------------------------------------------------
printf '=== rabbit-sweep smoke tests ===\n'
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
s11
s12
s13
s14
s15
s16
s17
s18
s19
s20
s21

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
