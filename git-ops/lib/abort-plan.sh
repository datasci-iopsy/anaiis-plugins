#!/usr/bin/env bash
# git-ops abort-plan: recover from a Phase 4-5 failure (exit 32/33/35) once a
# human has explicitly chosen "abort" from the three-way choice (fix and
# retry / skip a hook with --no-verify / abort). Never invoked automatically
# on failure detection -- the decision of which path to take always stays
# with the human; this script only executes "abort" once chosen.
# Usage: abort-plan.sh <run_dir>
# Prints one JSON line on success:
#   {ok, branch, tag_deleted, pre_abort_status, residual_status}
#
# Exit codes:
#   0  aborted
#  40  HEAD is not on tmp/rebase-<branch> -- refuses. This precondition also
#      makes it structurally impossible to invoke at exits 30/31, where the
#      tmp branch belongs to an unrelated prior run, not this one.
#  41  post-abort HEAD verification failed (should not happen; defensive)
#  42  tmp branch still exists after the delete (should not happen; defensive)
set -euo pipefail

RUN_DIR="$1"
RUN_JSON="${RUN_DIR}/run.json"

branch=$(jq -r '.branch' "$RUN_JSON")
tmp_branch="tmp/rebase-${branch}"
safety_tag="safety/pre-rebase-${branch}"

current_ref=$(git symbolic-ref --quiet HEAD || true)
if [ "$current_ref" != "refs/heads/${tmp_branch}" ]; then
	printf 'ERROR: HEAD is not on %s (currently: %s); refusing to abort -- this only runs right after a Phase 4-5 failure with the tmp branch checked out\n' \
		"$tmp_branch" "${current_ref:-detached}" >&2
	exit 40
fi

# Capture before doing anything destructive, so anything discarded is on the
# record even though no one watched a terminal do it.
pre_abort_status=$(git status --porcelain)

git switch -q --force "$branch"
git branch -q -D "$tmp_branch"

# Delete the safety tag only if it is provably redundant: the branch's
# current sha still equals the tag's sha, meaning nothing ever actually moved
# it (true for exit 32/33). If the branch moved to something else externally
# (exit 35), the tag is the only remaining record of the pre-rebase head and
# must survive -- never assume, always compare shas.
tag_deleted=false
if git rev-parse -q --verify "refs/tags/${safety_tag}" >/dev/null; then
	tag_sha=$(git rev-parse "refs/tags/${safety_tag}")
	branch_sha=$(git rev-parse "$branch")
	if [ "$tag_sha" = "$branch_sha" ]; then
		git tag -d "$safety_tag" >/dev/null
		tag_deleted=true
	fi
fi

# Verify post-state rather than trust set -e alone -- git switch/branch -D
# can fail on a stale index.lock or (in a linked worktree) the target branch
# being checked out elsewhere.
post_ref=$(git symbolic-ref --quiet HEAD || true)
if [ "$post_ref" != "refs/heads/${branch}" ]; then
	printf 'ERROR: post-abort HEAD is not on %s (got: %s)\n' "$branch" "${post_ref:-detached}" >&2
	exit 41
fi
if git rev-parse -q --verify "refs/heads/${tmp_branch}" >/dev/null; then
	printf 'ERROR: tmp branch %s still exists after abort\n' "$tmp_branch" >&2
	exit 42
fi

# Report any residual untracked state rather than asserting clean -- an
# artifact a hook dropped (lint cache, formatter backup) survives
# `git switch --force`.
residual_status=$(git status --porcelain)

jq -nc --arg branch "$branch" --argjson tag_deleted "$tag_deleted" \
	--arg pre "$pre_abort_status" --arg residual "$residual_status" \
	'{ok: true, branch: $branch, tag_deleted: $tag_deleted, pre_abort_status: $pre, residual_status: $residual}'
