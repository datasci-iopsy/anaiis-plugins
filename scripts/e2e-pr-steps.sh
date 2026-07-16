#!/usr/bin/env bash
# Headless verification of git-ops/skills/pr/SKILL.md steps 4 and 6, executed
# against a local bare origin. Proves: (1) the mktemp template substitutes a
# real random suffix and never creates a literal "pr-body-XXXXXX.md" file, and
# (2) the push step verifies success/up-to-date from repository state (SHA
# comparison), not from git's own text output. Never invokes step 7
# (`gh pr create`) or any network call.
#
# Run manually: bash scripts/e2e-pr-steps.sh
set -euo pipefail

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

REMOTE="${TMP}/origin.git"
WORK="${TMP}/work"

git init -q --bare "$REMOTE"
git init -q "$WORK"
git -C "$WORK" config user.name "Rabbit Sweep E2E"
git -C "$WORK" config user.email "rabbit-sweep-e2e@example.invalid"
(
	cd "$WORK"
	git commit -q --allow-empty -m init
	git checkout -q -b claude-feat/e2e-pr-steps
	git remote add origin "$REMOTE"
)

# --- Step 6 snippet: mktemp template ---------------------------------------
BODY_FILE=$(cd "$WORK" && mktemp "${TMPDIR:-/tmp}/pr-body.XXXXXX")

if [[ "$(basename "$BODY_FILE")" =~ ^pr-body\.[A-Za-z0-9]{6}$ ]]; then
	pass "step 6: mktemp substituted a real 6-char suffix (${BODY_FILE##*/})"
else
	fail "step 6: expected basename matching pr-body.[A-Za-z0-9]{6}, got ${BODY_FILE##*/}"
fi

if [ -e "$(dirname "$BODY_FILE")/pr-body-XXXXXX.md" ]; then
	fail "step 6: literal pr-body-XXXXXX.md was created (the original defect)"
else
	pass "step 6: no literal pr-body-XXXXXX.md file created"
fi
rm -f "$BODY_FILE"

# --- Step 4 snippet: push with -u, verify by SHA, not by message text ------
push_step4() {
	(
		cd "$WORK"
		BRANCH=$(git branch --show-current)
		git push -u origin "$BRANCH" >/dev/null 2>&1
	)
}

verify_step4() {
	(
		cd "$WORK"
		BRANCH=$(git branch --show-current)
		LOCAL=$(git rev-parse HEAD)
		REMOTE_SHA=$(git rev-parse "origin/${BRANCH}" 2>/dev/null || echo "MISSING")
		if [ "$LOCAL" != "$REMOTE_SHA" ]; then
			printf 'Push verification failed: HEAD=%s origin/%s=%s\n' "$LOCAL" "$BRANCH" "$REMOTE_SHA" >&2
			exit 1
		fi
		printf '%s\n' "$LOCAL"
	)
}

push_step4
first_sha=$(verify_step4) && first_ok=1 || first_ok=0
if [ "$first_ok" -eq 1 ]; then
	pass "step 4: first push verified by SHA equality (HEAD=${first_sha:0:8})"
else
	fail "step 4: first push failed SHA verification"
fi

# Repeat with no new commits -- git will print "Everything up-to-date"; the
# SHA check must pass regardless of that message (this is the CR-7 fix: never
# trust push output text, always compare state).
push_step4
second_sha=$(verify_step4) && second_ok=1 || second_ok=0
if [ "$second_ok" -eq 1 ] && [ "$second_sha" = "$first_sha" ]; then
	pass "step 4: repeat push (no new commits) still verified by SHA equality"
else
	fail "step 4: repeat push did not verify cleanly from state"
fi

# A real divergence (local ahead of remote, no push run yet this round) must
# be caught by the verify step alone, not silently reported as success.
(
	cd "$WORK"
	git commit -q --allow-empty -m "local-only commit, not yet pushed"
)
if verify_step4 >/dev/null 2>&1; then
	fail "step 4: expected an unpushed local commit to fail verification, but it passed"
else
	pass "step 4: a genuine local/remote divergence is caught (non-zero exit) before any push"
fi

# Never reaches step 7 (gh pr create) -- this harness makes no gh calls at all.

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
