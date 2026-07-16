#!/usr/bin/env bash
# git-ops apply-plan: execute a rebase-planner plan.json as branch reconstruction.
# Never uses `git rebase -i`; never force-pushes; never pushes at all.
# Usage: apply-plan.sh <run_dir>
# Reads <run_dir>/run.json (branch, fork_sha, head_sha) and <run_dir>/plan.json
# ({groups:[{message, commits[], files[]}], flagged[], rationale}).
# Prints one JSON line on success: {ok, branch, groups_committed, safety_tag}
#
# Exit codes:
#   0  reconstruction complete, tree verified equal, branch swapped
#  30  safety tag already exists (abort before any destructive action)
#  31  tmp branch already exists (abort before any destructive action)
#  32  pre-commit hook failed during a group commit (tag + tmp preserved)
#  33  non-empty diff after reconstruction (tag + tmp preserved)
#  34  same file path assigned to more than one group in plan.json (abort before any destructive action)
#  35  branch moved since the run.json snapshot; compare-and-swap aborted (tag + tmp preserved)
#  36  plan.json omits a path that changed between fork_sha and head_sha (abort before any destructive action)
set -euo pipefail

RUN_DIR="$1"
RUN_JSON="${RUN_DIR}/run.json"
PLAN_JSON="${RUN_DIR}/plan.json"

branch=$(jq -r '.branch' "$RUN_JSON")
fork_sha=$(jq -r '.fork_sha' "$RUN_JSON")
head_sha=$(jq -r '.head_sha' "$RUN_JSON")

safety_tag="safety/pre-rebase-${branch}"
tmp_branch="tmp/rebase-${branch}"

if git rev-parse -q --verify "refs/tags/${safety_tag}" >/dev/null; then
	printf 'ERROR: safety tag %s already exists; resolve or delete it before retrying\n' "$safety_tag" >&2
	exit 30
fi
if git rev-parse -q --verify "refs/heads/${tmp_branch}" >/dev/null; then
	printf 'ERROR: tmp branch %s already exists; resolve or delete it before retrying\n' "$tmp_branch" >&2
	exit 31
fi

dup_files=$(jq -r '.groups | to_entries[] | .key as $i | .value.files[] | "\(.)\t\($i)"' "$PLAN_JSON" | sort | cut -f1 | uniq -d)
if [ -n "$dup_files" ]; then
	printf 'ERROR: plan.json assigns the following file(s) to more than one group:\n' >&2
	while IFS= read -r dup_file; do
		group_idxs=$(jq -r --arg f "$dup_file" '.groups | to_entries[] | select(.value.files | index($f) != null) | (.key + 1)' "$PLAN_JSON" | paste -sd, -)
		printf '  %s (groups %s)\n' "$dup_file" "$group_idxs" >&2
	done <<<"$dup_files"
	exit 34
fi

# Coverage check: every path that changed between fork_sha and head_sha must
# be assigned to some group, or the final-state-wins reconstruction below
# (which only touches paths listed in plan.json) silently leaves fork_sha's
# stale content in place for any omitted path -- most commonly the old side
# of a rename whose file already existed at fork_sha. --no-renames forces
# both sides of a rename to be listed separately (a plain -M diff collapses
# a rename to a single name).
changed_paths=$(git diff --no-renames --name-only "$fork_sha" "$head_sha")
plan_paths=$(jq -r '.groups[].files[]' "$PLAN_JSON" | sort -u)
missing_paths=$(comm -23 <(printf '%s\n' "$changed_paths" | grep -v '^$' | sort -u) <(printf '%s\n' "$plan_paths" | grep -v '^$'))
if [ -n "$missing_paths" ]; then
	printf 'ERROR: plan.json does not cover the following path(s) changed between %s and %s:\n' "$fork_sha" "$head_sha" >&2
	printf '%s\n' "$missing_paths" | sed 's/^/  /' >&2
	exit 36
fi

git tag "$safety_tag" "$head_sha"
git checkout -q -b "$tmp_branch" "$fork_sha"

groups_committed=0
group_count=$(jq '.groups | length' "$PLAN_JSON")
for i in $(seq 0 $((group_count - 1))); do
	message=$(jq -r ".groups[$i].message" "$PLAN_JSON")
	files=$(jq -r ".groups[$i].files[]" "$PLAN_JSON")
	while IFS= read -r file; do
		[ -z "$file" ] && continue
		if git cat-file -e "${head_sha}:${file}" 2>/dev/null; then
			git checkout -q "$head_sha" -- "$file"
		else
			git rm -q --ignore-unmatch -- "$file" >/dev/null
		fi
	done <<<"$files"

	if git diff --cached --quiet; then
		continue # nothing staged for this group (files already matched fork state)
	fi

	commit_output=$(git commit -q -m "$message" 2>&1) || {
		printf 'ERROR: group commit failed for group %d ("%s")\n' "$((i + 1))" "$message" >&2
		printf '%s\n' "$commit_output" >&2
		printf 'Safety tag %s and tmp branch %s preserved.\n' "$safety_tag" "$tmp_branch" >&2
		printf 'Recovery: git checkout -f %s && git branch -D %s\n' "$branch" "$tmp_branch" >&2
		exit 32
	}
	groups_committed=$((groups_committed + 1))
done

tree_diff=$(git diff "$head_sha" "$tmp_branch")
if [ -n "$tree_diff" ]; then
	printf 'ERROR: tree verification failed; reconstructed tree differs from %s\n' "$head_sha" >&2
	printf '%s\n' "$tree_diff" >&2
	printf 'Safety tag %s and tmp branch %s preserved.\n' "$safety_tag" "$tmp_branch" >&2
	printf 'Recovery: git checkout -f %s && git branch -D %s\n' "$branch" "$tmp_branch" >&2
	exit 33
fi

tmp_sha=$(git rev-parse "$tmp_branch")
if ! git update-ref "refs/heads/${branch}" "$tmp_sha" "$head_sha"; then
	printf 'ERROR: branch %s has moved since the run.json snapshot (expected %s); aborting to avoid discarding new commits\n' "$branch" "$head_sha" >&2
	printf 'Safety tag %s and tmp branch %s preserved.\n' "$safety_tag" "$tmp_branch" >&2
	exit 35
fi

git checkout -q "$branch"
git branch -q -d "$tmp_branch"

jq -nc --arg branch "$branch" --argjson n "$groups_committed" --arg tag "$safety_tag" \
	'{ok: true, branch: $branch, groups_committed: $n, safety_tag: $tag}'
