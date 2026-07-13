#!/usr/bin/env bash
# git-ops git-state: create the run directory and write the artifacts every
# other git-ops script and agent reads from (commits.json, diffstat.txt,
# diff.patch, run.json).
# Usage: git-state.sh [branch] [base]
# Prints one JSON line: {run_dir, fork_sha, head_sha, commit_count}
#
# Exit codes:
#   0  artifacts written
#  20  no commits in range (nothing to rebase)
set -euo pipefail

BRANCH="${1:-$(git branch --show-current)}"
BASE="${2:-main}"

RUN_ROOT="${HOME}/.claude/anaiis-git-ops/runs"
mkdir -p "$RUN_ROOT"

fork_sha=$(git merge-base "$BASE" "$BRANCH")
head_sha=$(git rev-parse "$BRANCH")

shas=$(git log --reverse --format=%H "${fork_sha}..${BRANCH}")
if [ -z "$shas" ]; then
	printf '{"error":"no commits in range %s..%s"}\n' "$fork_sha" "$BRANCH" >&2
	exit 20
fi

# Noclobber run-dir creation: mkdir fails atomically if the dir already exists.
safe_branch="${BRANCH//\//-}"
iso=$(date -u +%Y%m%dT%H%M%SZ)
suffix=0
while :; do
	candidate="${RUN_ROOT}/${safe_branch}-${iso}${suffix:+-${suffix}}"
	if mkdir "$candidate" 2>/dev/null; then
		RUN_DIR="$candidate"
		break
	fi
	suffix=$((suffix + 1))
done

# commits.json: {sha, subject, files[], insertions, deletions} per commit, reverse-chron -> chron order.
commits_json="[]"
for sha in $shas; do
	subject=$(git show -s --format=%s "$sha")
	files_json="[]"
	ins_total=0
	del_total=0
	while IFS= read -r -d '' token; do
		[ -z "$token" ] && continue
		ins="${token%%$'\t'*}"
		rest="${token#*$'\t'}"
		del="${rest%%$'\t'*}"
		path="${rest#*$'\t'}"
		if [ -z "$path" ]; then
			# Rename/copy record: path field was empty, so the next two NUL-delimited
			# tokens are the old path (discard) and the new/destination path (use it).
			IFS= read -r -d '' _old_path
			IFS= read -r -d '' path
		fi
		files_json=$(jq -c --argjson f "$files_json" --arg file "$path" -n '$f + [$file]')
		[ "$ins" != "-" ] && ins_total=$((ins_total + ins))
		[ "$del" != "-" ] && del_total=$((del_total + del))
	done < <(git show --numstat -z --format= -M "$sha")
	commits_json=$(jq -c --argjson c "$commits_json" --arg sha "$sha" --arg subject "$subject" \
		--argjson files "$files_json" --argjson ins "$ins_total" --argjson del "$del_total" \
		-n '$c + [{sha: $sha, subject: $subject, files: $files, insertions: $ins, deletions: $del}]')
done
printf '%s\n' "$commits_json" >"${RUN_DIR}/commits.json"

git diff --stat -M "${fork_sha}..${BRANCH}" >"${RUN_DIR}/diffstat.txt"
git diff -M "${fork_sha}..${BRANCH}" >"${RUN_DIR}/diff.patch"

commit_count=$(printf '%s\n' "$shas" | wc -l | tr -d ' ')

jq -nc --arg branch "$BRANCH" --arg base "$BASE" --arg fork "$fork_sha" --arg head "$head_sha" --arg dir "$RUN_DIR" \
	'{branch: $branch, base: $base, fork_sha: $fork, head_sha: $head, run_dir: $dir}' >"${RUN_DIR}/run.json"

jq -nc --arg dir "$RUN_DIR" --arg fork "$fork_sha" --arg head "$head_sha" --argjson count "$commit_count" \
	'{run_dir: $dir, fork_sha: $fork, head_sha: $head, commit_count: $count}'
