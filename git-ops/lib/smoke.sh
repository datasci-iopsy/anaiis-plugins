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
# S6: git-state.sh artifacts, including both sides of a rename recorded
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

	# Both sides of the rename must be recorded, not just the new path:
	# apply-plan.sh's per-file reconstruction only removes a path if it is
	# both listed in some group's files and absent at head_sha, so dropping
	# the old path here strands it in the reconstructed tree whenever it
	# already existed before the fork point (see S16).
	local rename_files
	rename_files=$(jq -c '.[] | select(.subject == "refactor: rename b to b2") | .files' "${run_dir}/commits.json")
	if [ "$(printf '%s' "$rename_files" | jq 'index("b.txt") != null')" != "true" ] \
		|| [ "$(printf '%s' "$rename_files" | jq 'index("b2.txt") != null')" != "true" ]; then
		fail "S6: expected rename to list both old (b.txt) and new (b2.txt) paths, got ${rename_files}"
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

	pass "S6: git-state.sh artifacts (commits.json records both rename paths, diffstat, diff.patch, run.json)"
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
	local feat_add_sha
	feat_add_sha=$(git -C "$repo" rev-parse HEAD)
	echo "def test_f(): assert True" >"${repo}/test_feature.py"
	git -C "$repo" add test_feature.py && git -C "$repo" commit -q -m "test: add tests"
	local test_sha
	test_sha=$(git -C "$repo" rev-parse HEAD)
	echo "def f(): return 42" >"${repo}/feature.py"
	git -C "$repo" add feature.py && git -C "$repo" commit -q -m "feat: tweak feature"
	local feat_tweak_sha
	feat_tweak_sha=$(git -C "$repo" rev-parse HEAD)
	git -C "$repo" rm -q config.yml && git -C "$repo" commit -q -m "chore: remove config"
	local chore_sha
	chore_sha=$(git -C "$repo" rev-parse HEAD)

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/full main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<PLAN
{"groups": [
  {"message": "feat: implement feature", "commits": ["${feat_add_sha}", "${feat_tweak_sha}"], "files": ["feature.py"]},
  {"message": "test: add tests for feature", "commits": ["${test_sha}"], "files": ["test_feature.py"]},
  {"message": "chore: remove config", "commits": ["${chore_sha}"], "files": ["config.yml"]}
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
# S12: apply-plan.sh coverage check catches an incomplete (non-rename) plan
# before any destructive action (exit 36). Previously this scenario wasn't
# caught until after reconstruction, as a non-empty diff (exit 33); the
# coverage check now catches any omitted changed path -- rename or not --
# up front, so exit 33's tree-diff check is a defense-in-depth backstop that
# should no longer be reachable via a plan.json coverage gap alone.
# ---------------------------------------------------------------------------
s12() {
	local repo="${TMP}/s12"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/bad
	echo x >"${repo}/x.txt" && git -C "$repo" add x.txt && git -C "$repo" commit -q -m "feat: add x"
	local x_sha
	x_sha=$(git -C "$repo" rev-parse HEAD)
	echo y >"${repo}/y.txt" && git -C "$repo" add y.txt && git -C "$repo" commit -q -m "feat: add y"

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/bad main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<PLAN
{"groups": [{"message": "feat: add x", "commits": ["${x_sha}"], "files": ["x.txt"]}], "flagged": [], "rationale": "deliberately incomplete"}
PLAN

	(cd "$repo" && bash "${LIB}/apply-plan.sh" "$run_dir" >/dev/null 2>&1)
	local code=$?
	if [ "$code" -ne 36 ]; then
		fail "S12: apply-plan.sh incomplete plan expected exit 36, got ${code}"
		return
	fi
	if git -C "$repo" rev-parse -q --verify "refs/tags/safety/pre-rebase-feat/bad" >/dev/null; then
		fail "S12: exit 36 must fire before the safety tag is created"
		return
	fi
	pass "S12: apply-plan.sh coverage check catches an incomplete non-rename plan (exit 36, no destructive action)"
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
	local x_sha
	x_sha=$(git -C "$repo" rev-parse HEAD)

	mkdir -p "${repo}/.git/hooks"
	printf '#!/usr/bin/env bash\necho "simulated lint failure" >&2\nexit 1\n' >"${repo}/.git/hooks/pre-commit"
	chmod +x "${repo}/.git/hooks/pre-commit"

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/hook main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<PLAN
{"groups": [{"message": "feat: add x", "commits": ["${x_sha}"], "files": ["x.txt"]}], "flagged": [], "rationale": "smoke fixture"}
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
	local x_sha
	x_sha=$(git -C "$repo" rev-parse HEAD)

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/collide main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<PLAN
{"groups": [{"message": "feat: add x", "commits": ["${x_sha}"], "files": ["x.txt"]}], "flagged": [], "rationale": "smoke fixture"}
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
	local tools
	tools=$(awk '
		/^tools:$/ { in_tools=1; next }
		in_tools && /^  - / { sub(/^  - /, ""); print; next }
		in_tools { exit }
	' "$agent")
	if [ "$tools" != $'Read\nGrep' ]; then
		fail "S15: rebase-planner.md tools must be exactly Read, Grep (got: ${tools:-<empty>})"
		return
	fi
	if ! grep -q '"groups":' "$agent"; then
		fail "S15: rebase-planner.md missing output-contract marker"
		return
	fi
	pass "S15: rebase-planner agent contract (claude-sonnet-5, Read/Grep only, output contract present)"
}

# ---------------------------------------------------------------------------
# S16: apply-plan.sh coverage check catches a rename whose old path (already
# present at fork_sha) is omitted from plan.json (exit 36, no destructive
# action taken -- no safety tag, no tmp branch)
# ---------------------------------------------------------------------------
s16() {
	local repo="${TMP}/s16"
	new_repo "$repo"
	echo "old content" >"${repo}/old-name.md" && git -C "$repo" add old-name.md && git -C "$repo" commit -q -m "chore: init with pre-existing file"
	git -C "$repo" checkout -q -b feat/rename-preexisting
	git -C "$repo" mv old-name.md new-name.md && git -C "$repo" commit -q -m "refactor: rename old-name to new-name"
	local rename_sha
	rename_sha=$(git -C "$repo" rev-parse HEAD)

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/rename-preexisting main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<PLAN
{"groups": [{"message": "refactor: rename old-name to new-name", "commits": ["${rename_sha}"], "files": ["new-name.md"]}], "flagged": [], "rationale": "deliberately omits old-name.md"}
PLAN

	(cd "$repo" && bash "${LIB}/apply-plan.sh" "$run_dir" >/dev/null 2>&1)
	local code=$?
	if [ "$code" -ne 36 ]; then
		fail "S16: apply-plan.sh incomplete rename plan expected exit 36, got ${code}"
		return
	fi
	if git -C "$repo" rev-parse -q --verify "refs/tags/safety/pre-rebase-feat/rename-preexisting" >/dev/null; then
		fail "S16: exit 36 must fire before the safety tag is created"
		return
	fi
	if git -C "$repo" rev-parse -q --verify "refs/heads/tmp/rebase-feat/rename-preexisting" >/dev/null; then
		fail "S16: exit 36 must fire before the tmp branch is created"
		return
	fi
	pass "S16: apply-plan.sh coverage check catches an omitted rename path (exit 36, no destructive action)"
}

# ---------------------------------------------------------------------------
# S17: apply-plan.sh correctly reconstructs a rename of a file that already
# existed at fork_sha, once plan.json covers both paths (regression test for
# the tree-verification failure this session's rebase attempt hit)
# ---------------------------------------------------------------------------
s17() {
	local repo="${TMP}/s17"
	new_repo "$repo"
	echo "old content" >"${repo}/old-name.md" && git -C "$repo" add old-name.md && git -C "$repo" commit -q -m "chore: init with pre-existing file"
	git -C "$repo" checkout -q -b feat/rename-preexisting-ok
	git -C "$repo" mv old-name.md new-name.md && git -C "$repo" commit -q -m "refactor: rename old-name to new-name"
	local rename_sha
	rename_sha=$(git -C "$repo" rev-parse HEAD)
	echo "extra line" >>"${repo}/new-name.md" && git -C "$repo" add new-name.md && git -C "$repo" commit -q -m "fix: tweak renamed file"
	local tweak_sha
	tweak_sha=$(git -C "$repo" rev-parse HEAD)

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/rename-preexisting-ok main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<PLAN
{"groups": [{"message": "refactor: rename and tweak file", "commits": ["${rename_sha}", "${tweak_sha}"], "files": ["old-name.md", "new-name.md"]}], "flagged": [], "rationale": "covers both rename paths"}
PLAN

	local apply_out
	apply_out=$(cd "$repo" && bash "${LIB}/apply-plan.sh" "$run_dir")
	local code=$?
	if [ "$code" -ne 0 ]; then
		fail "S17: apply-plan.sh full-coverage rename plan expected exit 0, got ${code}"
		return
	fi
	if [ "$(printf '%s' "$apply_out" | jq -r '.ok')" != "true" ]; then
		fail "S17: apply-plan.sh expected ok:true"
		return
	fi
	if [ -f "${repo}/old-name.md" ]; then
		fail "S17: old-name.md should have been removed by reconstruction"
		return
	fi
	local content
	content=$(cat "${repo}/new-name.md")
	if [ "$content" != $'old content\nextra line' ]; then
		fail "S17: new-name.md should hold its final-state content, got: ${content}"
		return
	fi
	pass "S17: apply-plan.sh reconstructs a rename of a pre-existing file (old path removed, new path final content)"
}

# ---------------------------------------------------------------------------
# S18: apply-plan.sh detects the base (main) has advanced since run.json was
# captured, and aborts before any destructive action (exit 37, no safety tag,
# no tmp branch) instead of silently reconstructing onto a stale fork point.
# ---------------------------------------------------------------------------
s18() {
	local errors=0

	# Case 1: base genuinely advances *after* capture -- must abort, exit 37.
	local repo="${TMP}/s18a"
	new_repo "$repo"
	echo a >"${repo}/a.txt" && git -C "$repo" add a.txt && git -C "$repo" commit -q -m "chore: init"
	git -C "$repo" checkout -q -b feat/base-moved
	echo b >"${repo}/b.txt" && git -C "$repo" add b.txt && git -C "$repo" commit -q -m "feat: add b"
	local feat_sha
	feat_sha=$(git -C "$repo" rev-parse HEAD)

	local state_out run_dir
	state_out=$(cd "$repo" && bash "${LIB}/git-state.sh" feat/base-moved main)
	run_dir=$(printf '%s' "$state_out" | jq -r '.run_dir')
	cat >"${run_dir}/plan.json" <<PLAN
{"groups": [{"message": "feat: add b", "commits": ["${feat_sha}"], "files": ["b.txt"]}], "flagged": [], "rationale": "single group"}
PLAN

	# Advance main after the snapshot was captured.
	git -C "$repo" checkout -q main
	echo unrelated >"${repo}/c.txt" && git -C "$repo" add c.txt && git -C "$repo" commit -q -m "chore: unrelated main work"
	git -C "$repo" checkout -q feat/base-moved

	(cd "$repo" && bash "${LIB}/apply-plan.sh" "$run_dir" >/dev/null 2>&1)
	local code=$?
	if [ "$code" -ne 37 ]; then
		printf '  FAIL S18.1: expected exit 37 when base advances after capture, got %s\n' "$code"
		errors=$((errors + 1))
	fi
	if git -C "$repo" rev-parse -q --verify "refs/tags/safety/pre-rebase-feat/base-moved" >/dev/null; then
		printf '  FAIL S18.2: exit 37 must fire before the safety tag is created\n'
		errors=$((errors + 1))
	fi
	if git -C "$repo" rev-parse -q --verify "refs/heads/tmp/rebase-feat/base-moved" >/dev/null; then
		printf '  FAIL S18.3: exit 37 must fire before the tmp branch is created\n'
		errors=$((errors + 1))
	fi

	# Case 2 (regression guard): a branch that is simply behind main *before*
	# capture, with nothing changing afterward, must NOT be flagged as stale.
	# An earlier version of this check compared to fork_sha instead of a
	# captured base_sha snapshot and false-positived on this ordinary case.
	local repo2="${TMP}/s18b"
	new_repo "$repo2"
	echo a >"${repo2}/a.txt" && git -C "$repo2" add a.txt && git -C "$repo2" commit -q -m "chore: init"
	git -C "$repo2" checkout -q -b feat/behind-main
	echo b >"${repo2}/b.txt" && git -C "$repo2" add b.txt && git -C "$repo2" commit -q -m "feat: add b"
	local feat_sha2
	feat_sha2=$(git -C "$repo2" rev-parse HEAD)
	# main advances *before* git-state.sh ever runs -- ordinary, pre-existing drift.
	git -C "$repo2" checkout -q main
	echo unrelated >"${repo2}/c.txt" && git -C "$repo2" add c.txt && git -C "$repo2" commit -q -m "chore: pre-existing main work"
	git -C "$repo2" checkout -q feat/behind-main

	local state_out2 run_dir2
	state_out2=$(cd "$repo2" && bash "${LIB}/git-state.sh" feat/behind-main main)
	run_dir2=$(printf '%s' "$state_out2" | jq -r '.run_dir')
	cat >"${run_dir2}/plan.json" <<PLAN
{"groups": [{"message": "feat: add b", "commits": ["${feat_sha2}"], "files": ["b.txt"]}], "flagged": [], "rationale": "single group"}
PLAN

	local apply_out2
	apply_out2=$(cd "$repo2" && bash "${LIB}/apply-plan.sh" "$run_dir2")
	local code2=$?
	if [ "$code2" -ne 0 ]; then
		printf '  FAIL S18.4: expected exit 0 for an ordinary behind-main branch, got %s\n' "$code2"
		errors=$((errors + 1))
	elif [ "$(printf '%s' "$apply_out2" | jq -r '.ok')" != "true" ]; then
		printf '  FAIL S18.4: expected ok:true for an ordinary behind-main branch\n'
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S18: base-staleness check (exit 37 on real staleness, no false positive when merely behind main)"
	else
		fail "S18: base-staleness check (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# S19: find-reusable-plan.sh detects a byte-identical, same-branch, recent
# (<1h) plan to reuse, and correctly excludes a differing diffstat and a
# stale (>1h old) candidate. HOME is isolated to a temp dir since RUN_ROOT is
# under $HOME/.claude/anaiis-git-ops/runs, matching rabbit-sweep's S15 technique.
# ---------------------------------------------------------------------------
s19() {
	local errors=0
	local fake_home="${TMP}/s19-home"
	rm -rf "$fake_home"
	mkdir -p "$fake_home"
	local run_root="${fake_home}/.claude/anaiis-git-ops/runs"
	mkdir -p "$run_root"

	# A prior run for the same branch, recent, with a plan.json (reusable candidate).
	local prior_dir="${run_root}/feat-x-20260801T100000Z-0"
	mkdir -p "$prior_dir"
	printf ' a.txt | 1 +\n' >"${prior_dir}/diffstat.txt"
	printf '{"groups":[]}\n' >"${prior_dir}/plan.json"
	printf '{"branch":"feat/x"}\n' >"${prior_dir}/run.json"

	# The current run: identical diffstat.
	local current_dir="${run_root}/feat-x-20260801T100500Z-0"
	mkdir -p "$current_dir"
	printf ' a.txt | 1 +\n' >"${current_dir}/diffstat.txt"
	printf '{"branch":"feat/x"}\n' >"${current_dir}/run.json"

	local match
	match=$(HOME="$fake_home" bash "${LIB}/find-reusable-plan.sh" "$current_dir")
	if [ "$match" != "$prior_dir" ]; then
		printf '  FAIL S19.1: expected to match %s, got: %s\n' "$prior_dir" "$match"
		errors=$((errors + 1))
	fi

	# A different current diffstat must not match.
	local current_dir2="${run_root}/feat-x-20260801T101000Z-0"
	mkdir -p "$current_dir2"
	printf ' b.txt | 5 +\n' >"${current_dir2}/diffstat.txt"
	printf '{"branch":"feat/x"}\n' >"${current_dir2}/run.json"

	local match2
	match2=$(HOME="$fake_home" bash "${LIB}/find-reusable-plan.sh" "$current_dir2")
	if [ -n "$match2" ]; then
		printf '  FAIL S19.2: expected no match for a differing diffstat, got: %s\n' "$match2"
		errors=$((errors + 1))
	fi

	# A stale (>1h old) candidate with an otherwise identical diffstat must not match.
	# Remove the recent match first so only the stale one could possibly match.
	rm -rf "$prior_dir"
	local stale_dir="${run_root}/feat-x-20260801T010000Z-0"
	mkdir -p "$stale_dir"
	printf ' a.txt | 1 +\n' >"${stale_dir}/diffstat.txt"
	printf '{"groups":[]}\n' >"${stale_dir}/plan.json"
	printf '{"branch":"feat/x"}\n' >"${stale_dir}/run.json"
	touch -t "$(date -u -v-2H +%Y%m%d%H%M 2>/dev/null || date -u -d '2 hours ago' +%Y%m%d%H%M)" "$stale_dir"

	local current_dir3="${run_root}/feat-x-20260801T110000Z-0"
	mkdir -p "$current_dir3"
	printf ' a.txt | 1 +\n' >"${current_dir3}/diffstat.txt"
	printf '{"branch":"feat/x"}\n' >"${current_dir3}/run.json"

	local match3
	match3=$(HOME="$fake_home" bash "${LIB}/find-reusable-plan.sh" "$current_dir3")
	if [ -n "$match3" ]; then
		printf '  FAIL S19.3: expected no match for a stale (>1h) candidate, got: %s\n' "$match3"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "S19: find-reusable-plan.sh (identical diffstat matches, differing diffstat and stale candidates do not)"
	else
		fail "S19: find-reusable-plan.sh (${errors} checks failed)"
	fi
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
s16
s17
s18
s19

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
