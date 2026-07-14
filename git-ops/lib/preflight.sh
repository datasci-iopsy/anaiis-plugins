#!/usr/bin/env bash
# git-ops preflight: verify repo/branch state is safe for rebase reconstruction.
# Usage: preflight.sh [branch] [base]
# Prints one JSON line: {ok, checks:[{name, ok, detail}]}
#
# Exit codes (distinct per failure class so callers can branch without parsing JSON):
#   0  all checks pass
#  10  dirty working tree
#  11  detached HEAD (no named branch)
#  12  on main or master
#  13  merge commits present in range
#  14  requested branch does not match actual checkout
set -euo pipefail

actual_branch="$(git branch --show-current)"
if [ -n "${1:-}" ] && [ "$1" != "$actual_branch" ]; then
	branch_arg_mismatch=true
else
	branch_arg_mismatch=false
fi
BRANCH="$actual_branch"
BASE="${2:-main}"

checks='[]'
exit_code=0

add_check() {
	local name="$1" pass="$2" detail="$3"
	checks=$(jq -c --argjson c "$checks" --arg name "$name" --argjson pass "$pass" --arg detail "$detail" \
		-n '$c + [{name: $name, ok: $pass, detail: $detail}]')
}

# 1. Clean working tree
if [ -z "$(git status --porcelain)" ]; then
	add_check "clean_tree" true "working tree clean"
else
	add_check "clean_tree" false "uncommitted changes or untracked files present"
	exit_code=10
fi

# 2. Named branch (not detached HEAD)
if [ -n "$BRANCH" ]; then
	add_check "named_branch" true "on branch ${BRANCH}"
else
	add_check "named_branch" false "detached HEAD"
	[ "$exit_code" -eq 0 ] && exit_code=11
fi

# 2b. Requested branch matches actual checkout
if [ "$branch_arg_mismatch" = true ]; then
	add_check "branch_matches_checkout" false "requested branch '${1}' does not match current checkout '${actual_branch}'"
	[ "$exit_code" -eq 0 ] && exit_code=14
else
	add_check "branch_matches_checkout" true "requested branch matches current checkout"
fi

# 3. Not on main/master
if [ "$BRANCH" != "main" ] && [ "$BRANCH" != "master" ]; then
	add_check "not_main" true "branch is not main/master"
else
	add_check "not_main" false "refusing to reconstruct history on ${BRANCH}"
	[ "$exit_code" -eq 0 ] && exit_code=12
fi

# 4. No merge commits in range
if [ -n "$BRANCH" ]; then
	merge_count=$(git log --merges --oneline "${BASE}..${BRANCH}" 2>/dev/null | wc -l | tr -d ' ')
else
	merge_count=0
fi
if [ "$merge_count" -eq 0 ]; then
	add_check "no_merge_commits" true "no merge commits between ${BASE} and ${BRANCH}"
else
	add_check "no_merge_commits" false "${merge_count} merge commit(s) in range; refuse, needs manual handling"
	[ "$exit_code" -eq 0 ] && exit_code=13
fi

# 5. Upstream presence + divergence (informational; never fails preflight on its own)
upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
if [ -z "$upstream" ]; then
	add_check "upstream" true "no upstream; first push will be a plain push"
else
	if counts=$(git rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null); then
		read -r behind ahead <<<"$counts"
		add_check "upstream" true "upstream ${upstream}: ${ahead} ahead, ${behind} behind"
	else
		add_check "upstream" true "upstream ${upstream} configured but not resolvable locally"
	fi
fi

# 6. Worktree note (informational; never fails preflight on its own)
git_common_dir=$(git rev-parse --git-common-dir)
git_dir=$(git rev-parse --git-dir)
if [ "$git_common_dir" != "$git_dir" ]; then
	add_check "worktree" true "running inside a linked worktree"
else
	add_check "worktree" true "not a linked worktree"
fi

ok="false"
[ "$exit_code" -eq 0 ] && ok="true"

jq -nc --argjson ok "$ok" --argjson checks "$checks" '{ok: $ok, checks: $checks}'

exit "$exit_code"
