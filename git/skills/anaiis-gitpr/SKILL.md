---
name: anaiis-gitpr
description: "Explicit /anaiis-gitpr, open a pull request after CodeRabbit triage and commit cleanup"
user-invocable: true
trigger: manual
version: 0.1.0
---

# Git PR

Create a pull request for the current branch. Checks for an existing PR first, infers the base branch, generates a structured body from the git log, and opens the PR with self-assignment.

## When to use

Run after:
1. CodeRabbit triage is complete and all rated-4/5 fixes are committed
2. Commits have been cleaned up (anaiis-gitrebase if needed)

## Process

### 1. Preflight

```bash
git branch --show-current
git status --short
```

If the working tree is dirty, stop and report: "Uncommitted changes exist. Commit or stash before opening a PR."

### 2. Check for existing PR

```bash
gh pr list --head <current-branch> --json number,url --jq '.[0]'
```

If a PR already exists, report its URL and stop. Do not create a duplicate.

### 3. Determine base branch

- If the current branch matches `<type>/<id>--claude-<topic>` (Claude sub-branch pattern), the base is the parent feature branch: `<type>/<id>`.
- Otherwise, the base is `main`.

Confirm the base branch exists on the remote before proceeding:
```bash
gh api repos/{owner}/{repo}/branches/<base> --jq '.name' 2>/dev/null
```

### 4. Ensure branch is pushed

```bash
git push origin <current-branch> 2>&1
```

If the push fails, report the error and stop.

### 5. Generate PR title

Derive from the branch name. Given `feat/ana-858-wanting-to-work-analysis`:
- Type prefix: `feat`
- Linear ID: `ana-858`
- Title: `feat: wanting to work analysis (ana-858)`

Rules:
- Use a colon after the type, not an em dash
- Keep it under 72 characters
- Sentence case after the colon

### 6. Generate PR body

Write the body to a temp file to avoid shell quoting issues with multiline content and `#` characters:

```bash
BODY_FILE=$(mktemp /tmp/pr-body-XXXXXX.md)
```

Body structure:

```markdown
## Summary

<one paragraph: what this branch does and why>

## Changes

### Features
- <feature 1>
- <feature 2>

### Fixes
- <fix 1, derived from commit messages>

### Removed
- <removed item if applicable>

## Dev workflow

<make targets or run commands if a Makefile or script exists>
```

Populate from `git log <base>..<current-branch> --oneline` grouped by commit type (feat/fix/refactor/chore). If commit messages are not prefixed, group by logical theme.

### 7. Create the PR (DRAFT mode)

```bash
gh pr create \
  --base <base-branch> \
  --head <current-branch> \
  --title "<title>" \
  --body-file "$BODY_FILE" \
  --assignee @me \
  --draft
```

Do not pass `--json` to `gh pr create` -- it is not a valid flag for that command. The URL is printed to stdout on success.

Clean up the temp file after:
```bash
rm -f "$BODY_FILE"
```

### 8. Report

Print the PR URL. One line: `PR open (draft): <url>`

## What this skill does NOT do

- Does not add reviewers (user manages per project/team)
- Does not add labels or projects (not in current workflow)
- Does not push to main directly
- Does not merge
