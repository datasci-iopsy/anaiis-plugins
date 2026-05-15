# anaiis-gitrebase: Phase Detail

## Phase 1: Preflight (read-only)

Run as two separate Bash calls. The first resolves the fork SHA; the second uses it as a literal.

**Call 1, resolve fork point:**
```bash
git status --porcelain && \
git branch --show-current && \
git merge-base <base> HEAD
```

**Call 2, inspect range (substitute the literal SHA returned above for `<fork>`):**
```bash
git log --oneline <fork>..HEAD && \
git log --oneline --merges <fork>..HEAD
```

**Hard stops -- do not proceed if:**
- Working tree is dirty (`git status --porcelain` returns output) -- tell user to stash or commit first
- Merge commits exist in range (last command returns output) -- refuse; merge commits require manual handling
- Detached HEAD -- require a named branch
- No commits in range -- nothing to rebase

---

## Phase 2: Analysis (read-only)

```bash
git diff --stat <fork>..HEAD && \
git diff --name-only -M <fork>..HEAD && \
git log --oneline --name-only <fork>..HEAD
```

Use `-M` (rename detection) in `--name-only` so renames are grouped correctly rather than appearing as delete + add.

**Grouping heuristics:**
1. Source files in the same module or package group together
2. Test files group with the source files they test
3. Config, tooling, and CI changes (Makefile, pyproject.toml, .github/, linting configs) form their own commit
4. Documentation changes (README, CLAUDE.md) form their own commit unless tightly coupled to a specific feature
5. A file appearing in multiple original commits: use its final state, placed in the logical group matching its purpose
6. Binary files and submodules: flag explicitly and ask the user which group they belong to

**Output format:**

```
Proposed rebase plan (N files, M logical commits):

Commit 1: "feat(scope): description"
  Files:
  - path/to/file1.py
  - path/to/test_file1.py

Commit 2: "chore: description"
  Files:
  - pyproject.toml
  - Makefile
```

If `--dry-run`: output the plan and stop.

---

**GATE 1:** Present the plan and ask the user to confirm, modify, or reject the grouping before any destructive work begins.

---

## Phase 3: Execute (destructive)

**First: capture state and create the safety bookmark.**

Run each command separately (not chained with variable assignments) so each starts with `git`:

```bash
git rev-parse HEAD
git branch --show-current
git tag safety/pre-rebase-<branch> <sha>
```

Tell the user:

> Safety bookmark created: `safety/pre-rebase-<branch>` at `<sha>`.
> To revert at any time: `git checkout <branch> && git reset --hard safety/pre-rebase-<branch>`

**Then: build the temp branch.**

```bash
git checkout -b tmp/rebase-${BRANCH} <fork>
```

**For each commit group (in order):**

```bash
git checkout <literal-sha> -- <file1> <file2> ...
git commit -m "<message>"
```

**IMPORTANT -- command formatting:** Always substitute the SHA as a literal hex string directly in the command. Never use shell variable assignments like `FINAL=<sha> && git checkout ${FINAL} --`. Commands must start with `git`. If the shell cwd is not the repo root, prefix every command with `git -C <absolute-repo-root>`.

**File deletions:** if a file existed at the fork point but was deleted by HEAD, use `git rm <file>` in the appropriate group rather than `git checkout`.

**On pre-commit hook failure:** pause immediately. Report which hook tripped and the full output. Ask the user how to proceed:
1. Fix the issue (e.g., run `poetry lock`, fix lint errors) then retry
2. Skip the hook for this commit with `--no-verify` (requires explicit user approval)
3. Abort and revert to the safety tag

---

## Phase 4: Verify

```bash
git diff <literal-sha> tmp/rebase-<branch>
```

- **Empty diff:** "Tree equality verified. New history produces identical file contents."
- **Non-empty diff:** hard stop. Show the diff. Do NOT proceed. Offer to abort using literal branch/sha values.

---

**GATE 2:** User confirms verification passed and approves the branch swap.

---

## Phase 5: Swap

Use literal branch names (no shell variable expansions):

```bash
git checkout <branch>
git reset --hard tmp/rebase-<branch>
git branch -d tmp/rebase-<branch>
```

Output the final commit log:

```bash
git log <base>..HEAD --oneline
```

---

## Phase 6: Hand off (Claude does NOT push)

Present the result and the commands for the user to run:

```
Rebase complete. <N> clean commits:

  <sha> <commit 1 message>
  <sha> <commit 2 message>

To publish the rebased history, run:

  git push --force-with-lease origin <branch>

The safety tag `safety/pre-rebase-<branch>` remains. To revert after pushing:

  git reset --hard safety/pre-rebase-<branch>
  git push --force-with-lease origin <branch>

Delete the safety tag when you are satisfied:

  git tag -d safety/pre-rebase-<branch>
```

Claude does not execute the push. This is a human-only action.

---

## Failure modes and recovery

| Failure | Recovery |
|---|---|
| Dirty working tree | Stash (`git stash`) or commit, then re-run |
| Merge commits in range | Refuse; suggest `git rebase --onto` manually |
| Hook failure during commit | Pause, ask user: fix / skip (with approval) / abort |
| Tree verification fails | `git checkout <branch> && git reset --hard safety/pre-rebase-<branch> && git branch -D tmp/rebase-<branch>` |
| Process interrupted mid-execute | Same revert command as above |
| Wrong files in a group | Revert to safety tag, re-run with corrected grouping |
