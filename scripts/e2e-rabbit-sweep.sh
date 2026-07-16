#!/usr/bin/env bash
# Headless end-to-end verification of the rabbit-sweep skill: loads the
# WORKING-TREE copy of the review plugin into a nested `claude -p` session via
# `--plugin-dir` (session-scoped, no global plugin-cache or
# installed_plugins.json mutation), against a scratch fixture repo with a
# local bare origin and a shimmed `coderabbit` CLI. Never touches a real
# remote, never calls `gh`, and the prompt only ever invokes rabbit-sweep --
# `gh pr create` (pr skill step 7) is never reachable from this harness.
#
# Two runs:
#   1. Probe on the fixture's main branch -- asserts the branch-guard hard
#      stop (state-based: no commit, no ledger file created for this run).
#   2. Full auto run on a branch with a seeded flaw -- asserts a fix commit,
#      a no_tests ledger event (the fixture has no test suite), and a
#      SHA-verified push to the bare origin.
#
# Cleanup: this necessarily creates real files under
# ~/.claude/rabbit-sweep/runs/ (the skill's actual ledger store -- there is
# no isolation knob for it in a real session, unlike smoke.sh's LEDGER_DIR
# override). The harness deletes only the ledger/pointer files matching its
# own randomized branch name, never anything else in that directory.
#
# Requires the `claude` CLI on PATH and an authenticated session (OAuth or
# keychain -- --bare mode requires an API key and is not used here).
# Run manually: bash scripts/e2e-rabbit-sweep.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW_PLUGIN="${REPO_ROOT}/review"
LEDGER_STORE="${HOME}/.claude/rabbit-sweep/runs"
mkdir -p "$LEDGER_STORE"

if ! command -v claude >/dev/null 2>&1; then
	echo "SKIPPED: claude CLI not found on PATH -- cannot run the headless harness." >&2
	exit 0
fi

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

FIX=$(mktemp -d)
REPO="${FIX}/repo"
SUFFIX="$$-${RANDOM}"
FLAW_BRANCH="claude-test/e2e-${SUFFIX}"
SAFE_FLAW_BRANCH="${FLAW_BRANCH//\//-}"
NEW_BASE_LEDGER=""

cleanup() {
	rm -f "${LEDGER_STORE}/${SAFE_FLAW_BRANCH}"*.jsonl \
		"${LEDGER_STORE}/.current-${SAFE_FLAW_BRANCH}" 2>/dev/null || true
	if [ -n "$NEW_BASE_LEDGER" ]; then
		while IFS= read -r f; do
			[ -n "$f" ] && rm -f "$f"
		done <<<"$NEW_BASE_LEDGER"
	fi
	rm -rf "$FIX"
}
trap cleanup EXIT

# --- Fixture: repo + bare origin + main + flaw branch -----------------------
git init -q "$REPO"
git -C "$REPO" config user.name "Rabbit Sweep E2E"
git -C "$REPO" config user.email "rabbit-sweep-e2e@example.invalid"
git -C "$REPO" commit -q --allow-empty -m init
printf '# e2e fixture\n' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "init readme"

git -C "$REPO" branch -f "$FLAW_BRANCH" main 2>/dev/null || git -C "$REPO" branch -f "$FLAW_BRANCH" master
git -C "$REPO" checkout -q "$FLAW_BRANCH"
printf '#!/bin/bash\nrm -rf $DIR\n' >"$REPO/flaw.sh"
chmod +x "$REPO/flaw.sh"
git -C "$REPO" add flaw.sh
git -C "$REPO" commit -q -m "add flaw.sh"

BASE_BRANCH=$(git -C "$REPO" branch --list main master --format='%(refname:short)' | head -1)
SAFE_BASE_BRANCH="${BASE_BRANCH//\//-}"

git init -q --bare "$FIX/origin.git"
git -C "$REPO" remote add origin "$FIX/origin.git"
git -C "$REPO" push -q -u origin "$BASE_BRANCH"
git -C "$REPO" push -q -u origin "$FLAW_BRANCH"

# --- coderabbit shim + canned finding ---------------------------------------
mkdir -p "$FIX/bin"
cat >"$FIX/bin/coderabbit" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
	auth) echo '{"authenticated":true}' ;;
	review) cat "$FAKE_CODERABBIT_FIXTURE" ;;
	*) echo "unknown" >&2; exit 1 ;;
esac
SHIM
chmod +x "$FIX/bin/coderabbit"

cat >"$FIX/review.ndjson" <<EOF
{"type":"review_context","reviewType":"all","currentBranch":"${FLAW_BRANCH}","baseBranch":"${BASE_BRANCH}","workingDirectory":"${REPO}"}
{"type":"status","phase":"analyzing","status":"reviewing"}
{"type":"finding","severity":"major","fileName":"flaw.sh","codegenInstructions":"Verify each finding against current code.\n\nIn @flaw.sh at line 2, unquoted variable expansion in rm -rf can delete unintended paths if DIR is empty or contains spaces. Quote it.","suggestions":["rm -rf \\"\$DIR\\""]}
{"type":"complete","status":"review_completed","findings":1}
EOF

# --- Run 1: probe on the base branch -- expect the branch-guard hard stop --
git -C "$REPO" checkout -q "$BASE_BRANCH"
BASE_LEDGER_BEFORE=$(find "$LEDGER_STORE" -name "${SAFE_BASE_BRANCH}-*.jsonl" 2>/dev/null | sort)
PROBE_EXIT=0
(cd "$REPO" && timeout 90 claude -p --plugin-dir "$REVIEW_PLUGIN" --dangerously-skip-permissions \
	"Invoke the anaiis-review:rabbit-sweep skill with arguments: auto --base ${BASE_BRANCH}. Do exactly what the skill instructs, nothing more." \
	>/dev/null 2>&1) || PROBE_EXIT=$?
BASE_LEDGER_AFTER=$(find "$LEDGER_STORE" -name "${SAFE_BASE_BRANCH}-*.jsonl" 2>/dev/null | sort)
NEW_BASE_LEDGER=$(comm -13 <(printf '%s\n' "$BASE_LEDGER_BEFORE") <(printf '%s\n' "$BASE_LEDGER_AFTER"))

if [ "$(git -C "$REPO" rev-list --count "$BASE_BRANCH")" -eq 2 ]; then
	pass "probe: branch-guard blocked before any commit on ${BASE_BRANCH}"
else
	fail "probe: expected no new commits on ${BASE_BRANCH} after the branch-guard hard stop (probe exit ${PROBE_EXIT})"
fi
if [ -z "$NEW_BASE_LEDGER" ]; then
	pass "probe: no ledger file was created (Phase 3 never ran)"
else
	fail "probe: a ledger file was created despite the branch-guard hard stop (probe exit ${PROBE_EXIT})"
fi

# --- Run 2: full auto flow against the seeded flaw branch -------------------
git -C "$REPO" checkout -q "$FLAW_BRANCH"
FLAW_COMMIT=$(git -C "$REPO" rev-parse HEAD)

(
	cd "$REPO"
	PATH="${FIX}/bin:${PATH}" FAKE_CODERABBIT_FIXTURE="${FIX}/review.ndjson" \
		timeout 480 claude -p --plugin-dir "$REVIEW_PLUGIN" --dangerously-skip-permissions \
		"Invoke the anaiis-review:rabbit-sweep skill with arguments: auto --base ${BASE_BRANCH}. Do exactly what the skill instructs." \
		>/dev/null 2>&1
) || true

LOCAL_SHA=$(git -C "$REPO" rev-parse "$FLAW_BRANCH")
REMOTE_SHA=$(git -C "$REPO" rev-parse "origin/${FLAW_BRANCH}" 2>/dev/null || echo "MISSING")

if [ "$LOCAL_SHA" != "$FLAW_COMMIT" ]; then
	pass "full run: a new commit landed on ${FLAW_BRANCH} (fix committed)"
else
	fail "full run: no new commit landed -- the fix was never applied/committed"
fi
if git -C "$REPO" log "${FLAW_COMMIT}..${FLAW_BRANCH}" --oneline 2>/dev/null | grep -q '^[0-9a-f]* Fix CR-'; then
	pass "full run: commit message follows the Fix CR-<id> convention"
else
	fail "full run: no commit matching the Fix CR-<id> convention found"
fi
if ! grep -qF 'rm -rf $DIR' "$REPO/flaw.sh" && grep -qF 'rm -rf "$DIR"' "$REPO/flaw.sh"; then
	pass "full run: flaw.sh was actually fixed (variable quoted)"
else
	fail "full run: flaw.sh still contains the unquoted variable"
fi
if [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
	pass "full run: push verified by SHA equality (local HEAD == origin/${FLAW_BRANCH})"
else
	fail "full run: local/origin SHA mismatch after push (LOCAL=${LOCAL_SHA} REMOTE=${REMOTE_SHA})"
fi

LEDGER_FILE=$(find "$LEDGER_STORE" -name "${SAFE_FLAW_BRANCH}-*.jsonl" 2>/dev/null | head -1)
if [ -n "$LEDGER_FILE" ] && grep -q '"event":"no_tests"' "$LEDGER_FILE"; then
	pass "full run: ledger recorded a no_tests event (fixture has no test suite)"
else
	fail "full run: no no_tests ledger event found"
fi
if [ -n "$LEDGER_FILE" ] && grep -q '"event":"intent_verified"' "$LEDGER_FILE"; then
	pass "full run: ledger recorded intent_verified (two-stage verification completed)"
else
	fail "full run: no intent_verified ledger event found"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
