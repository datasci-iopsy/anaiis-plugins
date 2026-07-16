---
name: pr
description: "Explicit /anaiis-git-ops:pr, open a pull request after CodeRabbit triage and commit cleanup"
user-invocable: true
trigger: manual
version: 0.2.0
---

# Git PR

Create a pull request for the current branch. Checks for an existing PR first, infers the base branch, generates a structured body from the git log, and opens the PR with self-assignment.

## Arguments

```text
$ARGUMENTS: [auto]
```

This skill has no interactive gates today -- invoking it is already the authorization to
push and open a PR (see `rules/git.md`). `auto` (canonical) or `all` formalizes that
existing contract for consistency with the rest of the suite: it never pauses for
confirmation, and on any ambiguity or failure (dirty working tree, an existing PR, a base
branch missing on the remote, push verification failure) it reports the problem and stops
rather than asking. Without `auto`/`all`, behavior is identical. `--draft` (step 7) remains
the default in both cases.

## When to use

Run after:
1. CodeRabbit triage is complete and all rated-4/5 fixes are committed
2. Commits have been cleaned up (rebase if needed)

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

Push, then verify the remote actually matches local HEAD -- do not report success or
"up to date" from the push command's own text; both are read from repository state.

```bash
BRANCH=$(git branch --show-current)
if ! git push -u origin "$BRANCH" 2>&1; then
    printf 'Push failed; stopping before PR creation.\n' >&2
    exit 1
fi
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/${BRANCH}" 2>/dev/null || echo "MISSING")
if [ "$LOCAL" != "$REMOTE" ]; then
    printf 'Push verification failed: HEAD=%s origin/%s=%s\n' "$LOCAL" "$BRANCH" "$REMOTE"
    exit 1
fi
```

If the push command itself fails, report the error and stop. If it exits 0 but
`LOCAL` and `REMOTE` still disagree, report the mismatch above and stop -- do not
proceed to PR creation against an unverified remote state.

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
BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-body.XXXXXX")
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
