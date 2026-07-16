#!/usr/bin/env bash
# Shared branch preflight guard for rabbit-sweep (local mode Phase 1 and PR mode
# Phase 1'). Refuses to proceed on main/master or detached HEAD; otherwise prints
# the current branch to stdout and exits 0. No branch-pattern allowlist: any
# named non-main branch is authoritative, matching the repo's default-to-current
# convention (rules/git.md).
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	printf 'branch-guard: not a git repository\n' >&2
	exit 1
fi

BRANCH=$(git branch --show-current 2>/dev/null || true)

if [ -z "$BRANCH" ]; then
	printf 'branch-guard: detached HEAD -- checkout a branch first: git checkout -b claude-<category>/<short-description>\n' >&2
	exit 1
fi

if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
	printf 'branch-guard: refusing to run on %s -- create a branch first: git checkout -b claude-<category>/<short-description>\n' "$BRANCH" >&2
	exit 1
fi

printf '%s\n' "$BRANCH"
