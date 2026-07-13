#!/usr/bin/env bash
# Smoke tests for anaiis-git-ops's rebase-core lib scripts and agent contract.
# Run from the plugin root: bash lib/smoke.sh
# Exits 0 if all tests pass, non-zero if any test fails.

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${PLUGIN_ROOT}/lib"
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

new_repo() {
	local dir="$1"
	git init -q -b main "$dir"
	git -C "$dir" config user.email "smoke@test.com"
	git -C "$dir" config user.name "smoke"
	git -C "$dir" config commit.gpgsign false
	git -C "$dir" config tag.gpgsign false
	git -C "$dir" config core.hooksPath "$(git -C "$dir" rev-parse --git-dir)/hooks"
}

# ---------------------------------------------------------------------------
# S1: preflight.sh pass case
# ---------------------------------------------------------------------------
s1() {
	local repo="${TMP}/s1"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/x
	echo b >"${repo}/b.txt" && git -C "$repo" add b.txt && git -C "$repo" commit -q -m "feat: add b"

	local out code
	out=$(cd "$repo" && bash "${LIB}/preflight.sh" feat/x main)
	code=$?
	if [ "$code" -ne 0 ]; then
		fail "S1: preflight.sh pass case expected exit 0, got ${code}"
		return
	fi
	if [ "$(printf '%s' "$out" | jq -r '.ok')" != "true" ]; then
		fail "S1: preflight.sh pass case expected ok:true"
		return
	fi
	pass "S1: preflight.sh pass case (exit 0, ok:true)"
}

# ---------------------------------------------------------------------------
# S2: preflight.sh dirty tree (exit 10)
# ---------------------------------------------------------------------------
s2() {
	local repo="${TMP}/s2"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/x
	echo b >"${repo}/b.txt" && git -C "$repo" add b.txt && git -C "$repo" commit -q -m "feat: add b"
	echo dirty >>"${repo}/b.txt"

	(cd "$repo" && bash "${LIB}/preflight.sh" feat/x main >/dev/null 2>&1)
	local code=$?
	if [ "$code" -ne 10 ]; then
		fail "S2: preflight.sh dirty tree expected exit 10, got ${code}"
		return
	fi
	pass "S2: preflight.sh dirty tree (exit 10)"
}

# ---------------------------------------------------------------------------
# S3: preflight.sh on-main (exit 12)
# ---------------------------------------------------------------------------
s3() {
	local repo="${TMP}/s3"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"

	(cd "$repo" && bash "${LIB}/preflight.sh" main main >/dev/null 2>&1)
	local code=$?
	if [ "$code" -ne 12 ]; then
		fail "S3: preflight.sh on-main expected exit 12, got ${code}"
		return
	fi
	pass "S3: preflight.sh on-main (exit 12)"
}

# ---------------------------------------------------------------------------
# S4: preflight.sh merge commit in range (exit 13)
# ---------------------------------------------------------------------------
s4() {
	local repo="${TMP}/s4"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/x
	echo b >"${repo}/b.txt" && git -C "$repo" add b.txt && git -C "$repo" commit -q -m "feat: add b"
	git -C "$repo" checkout -q -b feat/other main
	echo c >"${repo}/c.txt" && git -C "$repo" add c.txt && git -C "$repo" commit -q -m "feat: add c"
	git -C "$repo" checkout -q feat/x
	git -C "$repo" merge -q --no-edit feat/other

	(cd "$repo" && bash "${LIB}/preflight.sh" feat/x main >/dev/null 2>&1)
	local code=$?
	if [ "$code" -ne 13 ]; then
		fail "S4: preflight.sh merge commit expected exit 13, got ${code}"
		return
	fi
	pass "S4: preflight.sh merge commit in range (exit 13)"
}

# ---------------------------------------------------------------------------
# S5: preflight.sh detached HEAD (exit 11)
# ---------------------------------------------------------------------------
s5() {
	local repo="${TMP}/s5"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/x
	echo b >"${repo}/b.txt" && git -C "$repo" add b.txt && git -C "$repo" commit -q -m "feat: add b"
	git -C "$repo" checkout -q --detach feat/x

	(cd "$repo" && bash "${LIB}/preflight.sh" "" main >/dev/null 2>&1)
	local code=$?
	if [ "$code" -ne 11 ]; then
		fail "S5: preflight.sh detached HEAD expected exit 11, got ${code}"
		return
	fi
	pass "S5: preflight.sh detached HEAD (exit 11)"
}

# ---------------------------------------------------------------------------
# S6: git-state.sh artifacts, including -M rename collapse to final path
# ---------------------------------------------------------------------------
s6() {
	local repo="${TMP}/s6"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/x
	echo b >"${repo}/b.txt" && git -C "$repo" add b.txt && git -C "$repo" commit -q -m "feat: add b"
	git -C "$repo" mv b.txt b2.txt && git -C "$repo" commit -q -m "refactor: rename b to b2"

	local out run_dir
	out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/x main)
	if [ $? -ne 0 ]; then
		fail "S6: git-state.sh expected exit 0"
		return
	fi
	run_dir=$(printf '%s' "$out" | jq -r '.run_dir')

	local count
	count=$(jq '. | length' "${run_dir}/commits.json")
	if [ "$count" -ne 2 ]; then
		fail "S6: expected 2 commits in commits.json, got ${count}"
		return
	fi

	local rename_files
	rename_files=$(jq -r '.[] | select(.subject == "refactor: rename b to b2") | .files[0]' "${run_dir}/commits.json")
	if [ "$rename_files" != "b2.txt" ]; then
		fail "S6: expected rename to collapse to final path b2.txt, got ${rename_files}"
		return
	fi

	[ -f "${run_dir}/diffstat.txt" ] || {
		fail "S6: diffstat.txt missing"
		return
	}
	[ -f "${run_dir}/diff.patch" ] || {
		fail "S6: diff.patch missing"
		return
	}
	[ -f "${run_dir}/run.json" ] || {
		fail "S6: run.json missing"
		return
	}

	pass "S6: git-state.sh artifacts (commits.json rename collapse, diffstat, diff.patch, run.json)"
}

# ---------------------------------------------------------------------------
# S7: git-state.sh no commits in range (exit 20)
# ---------------------------------------------------------------------------
s7() {
	local repo="${TMP}/s7"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"

	(cd "$repo" && bash "${LIB}/git-state.sh" main main >/dev/null 2>&1)
	local code=$?
	if [ "$code" -ne 20 ]; then
		fail "S7: git-state.sh no-commits-in-range expected exit 20, got ${code}"
		return
	fi
	pass "S7: git-state.sh no commits in range (exit 20)"
}

# ---------------------------------------------------------------------------
# S8-S10: group-commits.sh (all-prefixed, mixed, none-prefixed)
# ---------------------------------------------------------------------------
write_commits_json() {
	local dir="$1" json="$2"
	mkdir -p "$dir"
	printf '%s' "$json" >"${dir}/commits.json"
}

s8() {
	local dir="${TMP}/s8"
	write_commits_json "$dir" '[
    {"sha":"aaa1","subject":"feat: add x","files":["x.txt"],"insertions":1,"deletions":0},
    {"sha":"aaa2","subject":"fix: correct y","files":["y.txt"],"insertions":1,"deletions":1},
    {"sha":"aaa3","subject":"docs: update readme","files":["README.md"],"insertions":2,"deletions":0}
  ]'
	local out
	out=$(bash "${LIB}/group-commits.sh" "$dir")
	local n
	n=$(printf '%s' "$out" | jq '.groups | length')
	local ungrouped_n
	ungrouped_n=$(printf '%s' "$out" | jq '.ungrouped | length')
	if [ "$n" -ne 3 ] || [ "$ungrouped_n" -ne 0 ]; then
		fail "S8: group-commits.sh all-prefixed expected 3 groups/0 ungrouped, got ${n}/${ungrouped_n}"
		return
	fi
	pass "S8: group-commits.sh all-prefixed (3 groups, 0 ungrouped)"
}

s9() {
	local dir="${TMP}/s9"
	write_commits_json "$dir" '[
    {"sha":"bbb1","subject":"feat: add x","files":["x.txt"],"insertions":1,"deletions":0},
    {"sha":"bbb2","subject":"wip stuff","files":["y.txt"],"insertions":1,"deletions":0},
    {"sha":"bbb3","subject":"fix: correct x","files":["x.txt"],"insertions":1,"deletions":1}
  ]'
	local out n ungrouped_n
	out=$(bash "${LIB}/group-commits.sh" "$dir")
	n=$(printf '%s' "$out" | jq '.groups | length')
	ungrouped_n=$(printf '%s' "$out" | jq '.ungrouped | length')
	if [ "$n" -ne 2 ] || [ "$ungrouped_n" -ne 1 ]; then
		fail "S9: group-commits.sh mixed expected 2 groups/1 ungrouped, got ${n}/${ungrouped_n}"
		return
	fi
	pass "S9: group-commits.sh mixed (2 groups, 1 ungrouped)"
}

s10() {
	local dir="${TMP}/s10"
	write_commits_json "$dir" '[
    {"sha":"ccc1","subject":"wip stuff","files":["a.txt"],"insertions":1,"deletions":0},
    {"sha":"ccc2","subject":"more changes","files":["b.txt"],"insertions":1,"deletions":0}
  ]'
	local out n ungrouped_n
	out=$(bash "${LIB}/group-commits.sh" "$dir")
	n=$(printf '%s' "$out" | jq '.groups | length')
	ungrouped_n=$(printf '%s' "$out" | jq '.ungrouped | length')
	if [ "$n" -ne 0 ] || [ "$ungrouped_n" -ne 2 ]; then
		fail "S10: group-commits.sh none-prefixed expected 0 groups/2 ungrouped, got ${n}/${ungrouped_n}"
		return
	fi
	pass "S10: group-commits.sh none-prefixed (0 groups, 2 ungrouped)"
}

# ---------------------------------------------------------------------------
# S11: apply-plan.sh clean reconstruction, incl. final-state-wins and deletion
# ---------------------------------------------------------------------------
s11() {
	local repo="${TMP}/s11"
	new_repo "$repo"
	echo root >"${repo}/root.txt"
	echo cfg >"${repo}/config.yml"
	git -C "$repo" add root.txt config.yml && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/full
	echo "def f(): pass" >"${repo}/feature.py"
	git -C "$repo" add feature.py && git -C "$repo" commit -q -m "feat: add feature"
	echo "def test_f(): assert True" >"${repo}/test_feature.py"
	git -C "$repo" add test_feature.py && git -C "$repo" commit -q -m "test: add tests"
	echo "def f(): return 42" >"${repo}/feature.py"
	git -C "$repo" add feature.py && git -C "$repo" commit -q -m "feat: tweak feature"
	git -C "$repo" rm -q config.yml && git -C "$repo" commit -q -m "chore: remove config"

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/full main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<'PLAN'
{"groups": [
  {"message": "feat: implement feature", "commits": [], "files": ["feature.py"]},
  {"message": "test: add tests for feature", "commits": [], "files": ["test_feature.py"]},
  {"message": "chore: remove config", "commits": [], "files": ["config.yml"]}
], "flagged": [], "rationale": "smoke fixture"}
PLAN

	local apply_out
	apply_out=$(cd "$repo" && bash "${LIB}/apply-plan.sh" "$run_dir")
	local code=$?
	if [ "$code" -ne 0 ]; then
		fail "S11: apply-plan.sh clean reconstruction expected exit 0, got ${code}"
		return
	fi

	local ok groups_committed
	ok=$(printf '%s' "$apply_out" | jq -r '.ok')
	groups_committed=$(printf '%s' "$apply_out" | jq -r '.groups_committed')
	if [ "$ok" != "true" ] || [ "$groups_committed" -ne 3 ]; then
		fail "S11: apply-plan.sh expected ok:true, 3 groups committed"
		return
	fi

	if [ -f "${repo}/config.yml" ]; then
		fail "S11: config.yml should have been removed by reconstruction"
		return
	fi
	local content
	content=$(cat "${repo}/feature.py")
	if [ "$content" != "def f(): return 42" ]; then
		fail "S11: feature.py should hold its final-state content, got: ${content}"
		return
	fi

	local n_commits
	n_commits=$(git -C "$repo" log --oneline main..feat/full | wc -l | tr -d ' ')
	if [ "$n_commits" -ne 3 ]; then
		fail "S11: expected 3 reconstructed commits, got ${n_commits}"
		return
	fi

	pass "S11: apply-plan.sh clean reconstruction (final-state-wins, deletion, 3 commits)"
}

# ---------------------------------------------------------------------------
# S12: apply-plan.sh non-empty diff on an incomplete plan (exit 33)
# ---------------------------------------------------------------------------
s12() {
	local repo="${TMP}/s12"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/bad
	echo x >"${repo}/x.txt" && git -C "$repo" add x.txt && git -C "$repo" commit -q -m "feat: add x"
	echo y >"${repo}/y.txt" && git -C "$repo" add y.txt && git -C "$repo" commit -q -m "feat: add y"

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/bad main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<'PLAN'
{"groups": [{"message": "feat: add x", "commits": [], "files": ["x.txt"]}], "flagged": [], "rationale": "deliberately incomplete"}
PLAN

	(cd "$repo" && bash "${LIB}/apply-plan.sh" "$run_dir" >/dev/null 2>&1)
	local code=$?
	if [ "$code" -ne 33 ]; then
		fail "S12: apply-plan.sh incomplete plan expected exit 33, got ${code}"
		return
	fi
	if ! git -C "$repo" rev-parse -q --verify "refs/tags/safety/pre-rebase-feat/bad" >/dev/null; then
		fail "S12: safety tag should be preserved after exit 33"
		return
	fi
	pass "S12: apply-plan.sh non-empty diff (exit 33, safety tag preserved)"
}

# ---------------------------------------------------------------------------
# S13: apply-plan.sh pre-commit hook failure (exit 32)
# ---------------------------------------------------------------------------
s13() {
	local repo="${TMP}/s13"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/hook
	echo x >"${repo}/x.txt" && git -C "$repo" add x.txt && git -C "$repo" commit -q -m "feat: add x"

	mkdir -p "${repo}/.git/hooks"
	printf '#!/usr/bin/env bash\necho "simulated lint failure" >&2\nexit 1\n' >"${repo}/.git/hooks/pre-commit"
	chmod +x "${repo}/.git/hooks/pre-commit"

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/hook main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<'PLAN'
{"groups": [{"message": "feat: add x", "commits": [], "files": ["x.txt"]}], "flagged": [], "rationale": "smoke fixture"}
PLAN

	local err
	err=$(cd "$repo" && bash "${LIB}/apply-plan.sh" "$run_dir" 2>&1 1>/dev/null)
	local code=$?
	if [ "$code" -ne 32 ]; then
		fail "S13: apply-plan.sh hook failure expected exit 32, got ${code}"
		return
	fi
	if ! printf '%s' "$err" | grep -q "simulated lint failure"; then
		fail "S13: apply-plan.sh should surface the hook's stderr verbatim"
		return
	fi
	pass "S13: apply-plan.sh pre-commit hook failure (exit 32, hook output surfaced)"
}

# ---------------------------------------------------------------------------
# S14: apply-plan.sh safety-tag and tmp-branch collision guards (exit 30/31)
# ---------------------------------------------------------------------------
s14() {
	local repo="${TMP}/s14"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/collide
	echo x >"${repo}/x.txt" && git -C "$repo" add x.txt && git -C "$repo" commit -q -m "feat: add x"

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/collide main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<'PLAN'
{"groups": [{"message": "feat: add x", "commits": [], "files": ["x.txt"]}], "flagged": [], "rationale": "smoke fixture"}
PLAN

	git -C "$repo" tag "safety/pre-rebase-feat/collide"
	(cd "$repo" && bash "${LIB}/apply-plan.sh" "$run_dir" >/dev/null 2>&1)
	local tag_code=$?
	if [ "$tag_code" -ne 30 ]; then
		fail "S14: apply-plan.sh tag collision expected exit 30, got ${tag_code}"
		return
	fi
	git -C "$repo" tag -d "safety/pre-rebase-feat/collide" >/dev/null

	git -C "$repo" branch "tmp/rebase-feat/collide"
	(cd "$repo" && bash "${LIB}/apply-plan.sh" "$run_dir" >/dev/null 2>&1)
	local tmp_code=$?
	if [ "$tmp_code" -ne 31 ]; then
		fail "S14: apply-plan.sh tmp-branch collision expected exit 31, got ${tmp_code}"
		return
	fi
	pass "S14: apply-plan.sh safety-tag and tmp-branch collision guards (exit 30, 31)"
}

# ---------------------------------------------------------------------------
# S15: rebase-planner agent contract sentinels
# ---------------------------------------------------------------------------
s15() {
	local agent="${PLUGIN_ROOT}/agents/rebase-planner.md"
	if [ ! -f "$agent" ]; then
		fail "S15: rebase-planner.md not found"
		return
	fi
	if ! grep -q "^model: claude-sonnet-5" "$agent"; then
		fail "S15: rebase-planner.md must pin model: claude-sonnet-5"
		return
	fi
	if ! grep -A2 "^tools:" "$agent" | grep -q "Read" || ! grep -A2 "^tools:" "$agent" | grep -q "Grep"; then
		fail "S15: rebase-planner.md tools must include exactly Read and Grep"
		return
	fi
	if grep -A3 "^tools:" "$agent" | grep -qE "Bash|Write|Edit"; then
		fail "S15: rebase-planner.md tools must not include Bash/Write/Edit"
		return
	fi
	if ! grep -q '"groups":' "$agent"; then
		fail "S15: rebase-planner.md missing output-contract marker"
		return
	fi
	pass "S15: rebase-planner agent contract (claude-sonnet-5, Read/Grep only, output contract present)"
}

# ---------------------------------------------------------------------------
# Run all
# ---------------------------------------------------------------------------
printf '=== anaiis-git-ops smoke tests ===\n'
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

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
