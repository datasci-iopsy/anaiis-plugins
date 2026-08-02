#!/usr/bin/env bash
# git-ops find-reusable-plan: detect a recent, byte-identical rebase plan for
# the same branch so Phase 3 can skip re-spawning the planner agent.
# Usage: find-reusable-plan.sh <run_dir>
# Reads <run_dir>/run.json (.branch) and <run_dir>/diffstat.txt (the current diff).
# Prints the path of a matching prior RUN_DIR on stdout if found, nothing otherwise.
# Match criteria, all required: same branch (a sibling RUN_DIR, not this one),
# less than 1 hour old, diffstat.txt byte-identical, and a plan.json already present.
# When more than one candidate matches, the most recent one is printed.
# Exit codes:
#   0  ran successfully (a match was found, or not -- check stdout)
#   1  usage error (missing run_dir, run.json, or diffstat.txt)
set -euo pipefail

RUN_DIR="$1"
RUN_JSON="${RUN_DIR}/run.json"
CURRENT_DIFFSTAT="${RUN_DIR}/diffstat.txt"

if [ ! -f "$RUN_JSON" ] || [ ! -f "$CURRENT_DIFFSTAT" ]; then
	printf 'find-reusable-plan.sh: %s missing run.json or diffstat.txt\n' "$RUN_DIR" >&2
	exit 1
fi

branch=$(jq -r '.branch' "$RUN_JSON")
safe_branch="${branch//\//-}"
RUN_ROOT="${HOME}/.claude/anaiis-git-ops/runs"
ONE_HOUR=3600
now=$(date -u +%s)

match=""
match_mtime=-1
for candidate in "${RUN_ROOT}/${safe_branch}"-*; do
	[ -d "$candidate" ] || continue
	[ "$candidate" = "$RUN_DIR" ] && continue
	[ -f "${candidate}/plan.json" ] || continue
	[ -f "${candidate}/diffstat.txt" ] || continue

	candidate_branch=$(jq -r '.branch // empty' "${candidate}/run.json" 2>/dev/null) || continue
	[ "$candidate_branch" = "$branch" ] || continue

	mtime=$(stat -f '%m' "$candidate" 2>/dev/null || stat -c '%Y' "$candidate" 2>/dev/null || echo "")
	[ -z "$mtime" ] && continue
	age=$((now - mtime))
	[ "$age" -gt "$ONE_HOUR" ] && continue

	if cmp -s "$CURRENT_DIFFSTAT" "${candidate}/diffstat.txt" \
		&& [ "$mtime" -gt "$match_mtime" ]; then
		match="$candidate"
		match_mtime="$mtime"
	fi
done

if [ -n "$match" ]; then
	printf '%s\n' "$match"
fi
exit 0
