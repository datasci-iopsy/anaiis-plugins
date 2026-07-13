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

Spawn `Agent(subagent_type="rebase-planner", description="Plan rebase for <branch>")`
with `$RUN_DIR` as input. It reads `commits.json`, `diffstat.txt`, `diff.patch`, and
`draft-groups.json`, and returns one JSON line: `{groups, flagged, rationale}`. Write its
output to `$RUN_DIR/plan.json` verbatim.

Print the plan:

```
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
| 32 | pre-commit hook failed mid-reconstruction | stop; show the hook output verbatim; the tag and tmp branch are preserved; ask the user: fix and retry, skip the hook with explicit `--no-verify` approval, or abort via the recovery command in stderr |
| 33 | non-empty diff after reconstruction | stop; show the diff; the tag and tmp branch are preserved; do NOT proceed; offer the recovery command in stderr |

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

The safety tag `safety/pre-rebase-<branch>` remains. To revert:

  git reset --hard safety/pre-rebase-<branch>

Delete the safety tag when you are satisfied:

  git tag -d safety/pre-rebase-<branch>
```

If Phase 0 reported an existing upstream, substitute `git push --force-with-lease origin
<branch>` for the publish command and note that the revert command must be followed by
the same force-with-lease push. Claude does not execute the push. This is a human-only
action.

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
| Hook failure during commit (exit 32) | Fix / skip (with explicit approval) / abort via the printed recovery command |
| Tree verification fails (exit 33) | `git checkout <branch> && git reset --hard safety/pre-rebase-<branch> && git branch -D tmp/rebase-<branch>` |
| Process interrupted mid-execute | Same revert command as above; the safety tag always survives until the user deletes it |
