#!/usr/bin/env bash
# git-ops publish: decide, never execute, what push command Phase 6 should
# run next. Contains no bare --force/-f and never invokes `git push` itself
# anywhere -- the caller (Claude) runs the printed command as its own,
# separate Bash call, so the real permission system evaluates it, rather
# than a lib script laundering a denied command past that check.
# Usage: publish.sh <run_dir>
# Prints one JSON line: {mode, remote, branch, expect_sha, command, reason}
#   mode "plain": no remote ref for this branch yet; command sets tracking (-u).
#   mode "lease": a remote ref exists; command uses the explicit lease form,
#                 pinned to the sha `git ls-remote` just reported (not the
#                 local remote-tracking ref, which a background fetch from an
#                 unrelated skill could have silently moved).
#   mode "refuse": caller should fall back to printing the manual command.
#
# Exit codes:
#   0   mode plain or lease decided
#  50  run.json's repo_root does not match the cwd's repo (stale/wrong-repo run_dir)
#  51  branch is main/master or matches the remote's resolved default branch
#  52  branch's current tip does not match result.json's new_sha (nothing
#      proves this tip is what Phase 4-5 tree-verified, or Phase 4-5 never
#      completed for this run_dir)
#  53  git ls-remote failed (offline, auth, misconfigured remote)
set -euo pipefail

RUN_DIR="$1"
RUN_JSON="${RUN_DIR}/run.json"
RESULT_JSON="${RUN_DIR}/result.json"

branch=$(jq -r '.branch' "$RUN_JSON")
recorded_root=$(jq -r '.repo_root' "$RUN_JSON")

refuse() {
	local reason="$1"
	jq -nc --arg branch "$branch" --arg reason "$reason" \
		'{mode: "refuse", remote: null, branch: $branch, expect_sha: null, command: null, reason: $reason}'
}

actual_root=$(git rev-parse --show-toplevel)
if [ "$recorded_root" != "$actual_root" ]; then
	refuse "run.json repo_root (${recorded_root}) does not match the current repo (${actual_root})"
	exit 50
fi

default_branch=""
remote=$(git config --get "branch.${branch}.remote" 2>/dev/null || true)
[ -z "$remote" ] && remote="origin"
default_ref=$(git symbolic-ref --quiet "refs/remotes/${remote}/HEAD" 2>/dev/null || true)
[ -n "$default_ref" ] && default_branch="${default_ref#refs/remotes/"${remote}"/}"

if [ "$branch" = "main" ] || [ "$branch" = "master" ] || { [ -n "$default_branch" ] && [ "$branch" = "$default_branch" ]; }; then
	refuse "refusing to push ${branch}: it is main/master or the remote's default branch"
	exit 51
fi

if [ ! -f "$RESULT_JSON" ]; then
	refuse "no result.json for this run_dir; Phase 4-5 never completed successfully"
	exit 52
fi
new_sha=$(jq -r '.new_sha' "$RESULT_JSON")
branch_sha=$(git rev-parse "$branch")
if [ "$branch_sha" != "$new_sha" ]; then
	refuse "branch ${branch}'s current tip (${branch_sha}) does not match result.json's new_sha (${new_sha}); something else was committed since, or this result.json is stale"
	exit 52
fi

remote_sha=$(git ls-remote --exit-code "$remote" "refs/heads/${branch}" 2>/dev/null | cut -f1) || true
if [ -z "$remote_sha" ]; then
	if ! git ls-remote --exit-code "$remote" >/dev/null 2>&1; then
		refuse "could not query remote ${remote} (offline, auth failure, or misconfigured)"
		exit 53
	fi
	# Remote reachable, just no ref for this branch yet.
	command="git push -u ${remote} ${branch}"
	jq -nc --arg remote "$remote" --arg branch "$branch" --arg command "$command" \
		'{mode: "plain", remote: $remote, branch: $branch, expect_sha: null, command: $command, reason: null}'
	exit 0
fi

command="git push --force-with-lease=${branch}:${remote_sha} ${remote} ${branch}"
jq -nc --arg remote "$remote" --arg branch "$branch" --arg sha "$remote_sha" --arg command "$command" \
	'{mode: "lease", remote: $remote, branch: $branch, expect_sha: $sha, command: $command, reason: null}'
