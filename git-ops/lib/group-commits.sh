#!/usr/bin/env bash
# git-ops group-commits: deterministic draft grouping of commits.json by
# conventional-commit prefix (feat/fix/refactor/chore/docs/test/style/perf/build/ci).
# Unprefixed commits land in "ungrouped" for the rebase-planner agent to place.
# Usage: group-commits.sh <run_dir>
# Writes <run_dir>/draft-groups.json. Prints the same JSON to stdout. Never fails.
set -euo pipefail

RUN_DIR="$1"
COMMITS="${RUN_DIR}/commits.json"

groups="[]"
ungrouped="[]"

shas=$(jq -r '.[].sha' "$COMMITS")
for sha in $shas; do
	subject=$(jq -r --arg sha "$sha" '.[] | select(.sha == $sha) | .subject' "$COMMITS")
	type=$(printf '%s' "$subject" | grep -oE '^(feat|fix|refactor|chore|docs|test|style|perf|build|ci)(\([^)]*\))?:' | grep -oE '^[a-z]+' || true)

	if [ -z "$type" ]; then
		ungrouped=$(jq -c --argjson u "$ungrouped" --arg sha "$sha" -n '$u + [$sha]')
		continue
	fi

	has_group=$(jq -r --argjson g "$groups" --arg t "$type" -n '($g | map(.type == $t) | any)')
	if [ "$has_group" = "true" ]; then
		groups=$(jq -c --argjson g "$groups" --arg t "$type" --arg sha "$sha" \
			-n '$g | map(if .type == $t then .commits += [$sha] else . end)')
	else
		groups=$(jq -c --argjson g "$groups" --arg t "$type" --arg sha "$sha" \
			-n '$g + [{type: $t, commits: [$sha]}]')
	fi
done

jq -nc --argjson groups "$groups" --argjson ungrouped "$ungrouped" '{groups: $groups, ungrouped: $ungrouped}' | tee "${RUN_DIR}/draft-groups.json"
