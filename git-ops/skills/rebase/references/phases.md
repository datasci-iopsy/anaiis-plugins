# rebase: Phase Detail

Resolve `LIB_DIR` once at the start of the run: two directories up from this skill's own
base directory (shown in your invocation context), then `/lib`. All phases below invoke
scripts as `bash "$LIB_DIR/<script>.sh" ...`.

---

## Phase 0: Preflight

```bash
bash "$LIB_DIR/preflight.sh" <branch> <base>
```

Parse the JSON verdict on stdout. Exit code maps to a hard stop:

| Exit | Meaning | Action |
|---|---|---|
| 0 | all checks pass | continue to Phase 1 |
| 10 | dirty working tree | stop; tell the user to commit or stash |
| 11 | detached HEAD | stop; tell the user to check out a named branch |
| 12 | on main/master | stop; refuse |
| 13 | merge commits in range | stop; refuse, merge commits require manual handling |

The `upstream` and `worktree` entries in the JSON are informational; carry the upstream
divergence detail forward to Phase 6's hand-off message.

---

## Phase 1: Git state

```bash
bash "$LIB_DIR/git-state.sh" <branch> <base>
```

Prints `{run_dir, fork_sha, head_sha, commit_count}` on success and creates
`$RUN_DIR/{commits.json,diffstat.txt,diff.patch,run.json}`. Exit 20 means no commits in
range: report "Nothing to rebase between `<base>` and `<branch>`." and stop.

Capture `RUN_DIR` from the output; every later phase in this run uses it.

---

## Phase 2: Deterministic draft grouping

```bash
bash "$LIB_DIR/group-commits.sh" "$RUN_DIR"
```

Writes `$RUN_DIR/draft-groups.json`. Never fails; always continue to Phase 3.

---

## Phase 3: Planner agent

Before spawning the planner, check whether an identical plan already exists for this branch:
```bash
REUSE=$(bash "$LIB_DIR/find-reusable-plan.sh" "$RUN_DIR")
```
If `$REUSE` is non-empty, verify it before reusing: confirm `${REUSE}/run.json` and
`${RUN_DIR}/run.json` have identical `base_sha`, `fork_sha`, and `head_sha`, and that
`${REUSE}/diff.patch` and `${RUN_DIR}/diff.patch` are byte-identical (`cmp -s`). If any
check fails, treat `$REUSE` as empty and spawn the planner as normal instead of copying.

If `$REUSE` is non-empty and passes verification:
- **Without `--confirm`** (the default): copy the match's plan verbatim, print that it was
  reused, and skip straight to printing the plan below -- do not spawn the planner.
  ```bash
  cp "${REUSE}/plan.json" "${RUN_DIR}/plan.json"
  printf 'Reusing identical plan from %s (byte-identical diffstat, within the last hour).\n' "$REUSE"
  ```
  This keeps the default "runs end-to-end without pausing" behavior (see `SKILL.md`) while
  still being visible, not silent, about what it did.
- **With `--confirm`**: ask the user "An identical diff was already planned in `<REUSE>`.
  Reuse that plan? (y/n)" -- on yes, copy `plan.json` as above; on no, proceed to spawn the
  planner as normal.

If `$REUSE` is empty, spawn the planner as normal:

Spawn `Agent(subagent_type="rebase-planner", description="Plan rebase for <branch>")`
with `$RUN_DIR` as input. It reads `commits.json`, `diffstat.txt`, `diff.patch`, and
`draft-groups.json`, and returns one JSON line: `{groups, flagged, rationale}`. Write its
output to `$RUN_DIR/plan.json` verbatim.

Print the plan:

```text
Proposed rebase plan (<N> groups):

Group 1: "<message>"
  - <file>
  - <file>

Group 2: "<message>"
  - <file>
```

If `flagged` is non-empty, list the paths and ask the user which group each belongs to
before proceeding; add the user's answer to the corresponding group's `files` in
`plan.json` before Phase 4.

- `--dry-run`: stop here. Do not invoke Phase 4.
- `--confirm`: ask the user to confirm, modify, or reject the plan before proceeding.
- Otherwise: proceed directly to Phase 4 (the plan itself is the deterministic-enough
  gate; only anomalies pause the default run).

---

## Phase 4-5: Apply and verify

```bash
bash "$LIB_DIR/apply-plan.sh" "$RUN_DIR"
```

This single script call creates the safety tag, builds the tmp branch, commits each
group in order, verifies tree equality against the original HEAD, and swaps the branch
into place. Exit code:

| Exit | Meaning | Action |
|---|---|---|
| 0 | success; branch swapped | continue to Phase 6 |
| 30 | safety tag already exists | stop; tell the user to resolve or delete the stale tag |
| 31 | tmp branch already exists | stop; tell the user to resolve or delete the stale branch |
| 32 | group commit failed mid-reconstruction | stop; show the commit output verbatim; the tag and tmp branch are preserved; ask the user: fix and retry, skip a failing hook with explicit `--no-verify` approval, or abort via the recovery command in stderr |
| 33 | non-empty diff after reconstruction | stop; show the diff; the tag and tmp branch are preserved; do NOT proceed; offer the recovery command in stderr |
| 34 | same file path assigned to more than one group in plan.json | stop; show the duplicated path(s) and group indices from stderr; no destructive action was taken; ask the user or re-run planning to fix `plan.json` |
| 36 | plan.json omits a path that changed between fork and head (most commonly one side of a rename whose file already existed before the branch) | stop; show the missing path(s) from stderr; no destructive action was taken; ask the user or re-run planning to add the missing path(s) to `plan.json` |
| 37 | base has moved since this plan was captured (advanced or diverged from its snapshot) | stop; show the message from stderr (advanced -> re-run Phase 1 to recapture, then re-plan; diverged -> investigate before proceeding); no destructive action was taken |

---

## Phase 6: Hand off (Claude does NOT push)

```bash
git log <base>..<branch> --oneline
```

Present the result and the command for the user to run. If Phase 0 reported no upstream:

```
Rebase complete. <N> clean commits:

  <sha> <commit 1 message>
  <sha> <commit 2 message>

To publish, run:

  git push origin <branch>

---
Only if you need to undo this (do NOT run this after a successful push -- it will locally
revert what you just pushed; origin is unaffected until you push again, but your local
branch and origin will disagree):

  git reset --hard safety/pre-rebase-<branch>

Once satisfied the push is correct and you no longer need the safety net:

  git tag -d safety/pre-rebase-<branch>
---
```

If Phase 0 reported an existing upstream, substitute `git push --force-with-lease origin
<branch>` for the publish command in the block above, and note in the same "Only if you need
to undo this" warning that the revert must be followed by the same force-with-lease push to
resync. Claude does not execute the push. This is a human-only action.

---

## Failure modes and recovery

| Failure | Recovery |
|---|---|
| Dirty working tree (exit 10) | Stash or commit, then re-run |
| Detached HEAD (exit 11) | Check out a named branch, then re-run |
| On main/master (exit 12) | Check out the correct feature branch |
| Merge commits in range (exit 13) | Refuse; suggest `git rebase --onto` manually |
| No commits in range (exit 20) | Nothing to do |
| Safety tag or tmp branch collision (exit 30/31) | Resolve or delete the stale ref, then re-run |
| Commit failure during group commit (exit 32) | Fix / skip (with explicit approval) / abort via the printed recovery command |
| Tree verification fails (exit 33) | `git checkout <branch> && git reset --hard safety/pre-rebase-<branch> && git branch -D tmp/rebase-<branch>` |
| Duplicate file across groups (exit 34) | Fix `plan.json` (or re-run planning) so each file appears in exactly one group, then re-run |
| plan.json omits a changed path (exit 36) | Add the missing path(s) to the appropriate group in `plan.json` (or re-run planning), then re-run. Common cause: a rename of a file that already existed before the branch -- both the old and new path must be covered |
| Base moved since capture (exit 37) | Re-run Phase 1 (`git-state.sh`) to recapture, then re-plan (Phase 2-3), before retrying apply |
| Process interrupted mid-execute | Same revert command as above; the safety tag always survives until the user deletes it |
| Ran `git reset --hard safety/pre-rebase-<branch>` after already pushing | `git reset --hard origin/<branch>` to resync local to what's on origin (verify with `git status` and `git log --oneline origin/<branch>..HEAD` first) |
