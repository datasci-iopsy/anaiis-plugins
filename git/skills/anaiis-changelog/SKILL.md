---
name: anaiis-changelog
description: Generate a changelog or release notes from the current branch diff for PR preparation
user-invocable: true
trigger: manual
version: 0.1.0
---

# Changelog

Generate a concise summary of changes on the current branch for PR preparation.

## Context injected automatically
- Current branch: `!git branch --show-current`
- Base branch: `!git merge-base --fork-point main HEAD 2>/dev/null || echo "main"`

## Process

1. Identify the base branch (default: `main`) and the fork point
2. List all commits since the fork: `git log --oneline <fork-point>..HEAD`
3. Show the full diff stat: `git diff --stat <fork-point>..HEAD`
4. For each file changed, read the diff and summarize the intent (not just "modified X")
5. Group changes by category: feature, fix, refactor, docs, test, chore

## Output format

### Changes on `<branch>` (N commits, M files)

**Features:**
- Description of feature change (files involved)

**Fixes:**
- Description of fix (files involved)

**Refactoring:**
- Description of refactor (files involved)

**Docs/Other:**
- Description (files involved)

### Suggested PR title
`<imperative mood, under 70 chars>`

### Suggested PR body
A 2-3 sentence summary suitable for the PR description.
