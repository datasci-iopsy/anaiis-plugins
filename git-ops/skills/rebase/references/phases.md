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
| 0 | success; branch swapped, `result.json` written | continue to Phase 6 |
| 30 | safety tag already exists and points elsewhere | stop; tell the user to resolve or delete the stale tag (a stale tag pointing at this run's own `head_sha` does not block; see 32/33/35 below) |
| 31 | tmp branch already exists | stop; tell the user to resolve or delete the stale branch |
| 32 | group commit failed mid-reconstruction | tag and tmp branch preserved; see "Recovery choice" below |
| 33 | non-empty diff after reconstruction | tag and tmp branch preserved; see "Recovery choice" below |
| 34 | same file path assigned to more than one group in plan.json | stop; show the duplicated path(s) and group indices from stderr; no destructive action was taken; ask the user or re-run planning to fix `plan.json` |
| 35 | branch moved externally between capture and swap (compare-and-swap failed) | tag and tmp branch preserved; see "Recovery choice" below -- **the safety tag must not be deleted here**, it is the only remaining record of the pre-rebase head once the branch itself has moved |
| 36 | plan.json omits a path that changed between fork and head (most commonly one side of a rename whose file already existed before the branch) | stop; show the missing path(s) from stderr; no destructive action was taken; ask the user or re-run planning to add the missing path(s) to `plan.json` |
| 37 | base has moved since this plan was captured (advanced or diverged from its snapshot) | stop; show the message from stderr (advanced -> re-run Phase 1 to recapture, then re-plan; diverged -> investigate before proceeding); no destructive action was taken |

**Recovery choice (exit 32, 33, or 35):** present the human with three options -- this
decision always stays with the human, never automatic on failure detection:

- **Fix and retry**: address the cause (failing hook, unexpected diff, external branch
  move), then re-run `apply-plan.sh "$RUN_DIR"`. A stale tag from the failed attempt at
  the same `head_sha` will not block this (exit 30's relaxation above).
- **Skip a failing hook** (exit 32 only): with explicit human approval in the moment,
  re-run as `APPLY_PLAN_NO_VERIFY=1 bash "$LIB_DIR/apply-plan.sh" "$RUN_DIR"`. Never set
  this as a default; only after the human has approved skipping this specific hook.
- **Abort**: run `bash "$LIB_DIR/abort-plan.sh" "$RUN_DIR"`. This executes the recovery
  the human chose -- it does not decide to abort on its own. It refuses (exit 40) unless
  HEAD is still on the tmp branch, restores HEAD to the real branch, deletes the tmp
  branch, and deletes the safety tag only if it is provably redundant (branch sha == tag
  sha, true for 32/33, never true for 35). Prints `pre_abort_status`/`residual_status`
  from `git status --porcelain` so anything discarded is on the record; report
  `residual_status` to the user rather than assuming the abort left a clean tree.

---

## Phase 6: Publish

```bash
git log <base>..<branch> --oneline
bash "$LIB_DIR/publish.sh" "$RUN_DIR"
```

`publish.sh` only ever decides and prints what to run next; it never pushes anything
itself. Parse its JSON (`{mode, remote, branch, expect_sha, command, reason}`):

- **`mode: "refuse"`**: fall back to the manual hand-off below, including `reason`.
- **`mode: "plain"` or `"lease"`**: this is the moment the *real* permission system
  evaluates the actual `git push ...` string -- it is not laundered through a script, so
  a still-unnarrowed deny rule blocks it here exactly as it would in any other context.
  If `--confirm` was passed at invocation, show `command` and ask before running it
  (same review gate `--confirm` already applies to the plan in Phase 3); otherwise run it
  directly as its own Bash call. If the call is denied or the push otherwise fails, fall
  back to the manual hand-off below -- do not retry with a different flag, and never
  escalate a plain push to a forced one.
- **After a successful push**: re-verify by reading `git rev-parse <remote>/<branch>` and
  comparing to the local branch sha -- a push can exit non-zero after the ref actually
  moved, or print an ambiguous "Everything up-to-date." Report the verified sha, not just
  the command's exit code.

Manual hand-off (used whenever `publish.sh` refuses, or the push above was denied/failed):

```
Rebase complete. <N> clean commits:

  <sha> <commit 1 message>
  <sha> <commit 2 message>

To publish, run:

  <command from publish.sh, or a plain `git push origin <branch>` if publish.sh itself
  refused before deciding a command>

---
Only if you need to undo this (do NOT run this after a successful push -- it will locally
revert what you just pushed; origin is unaffected until you push again, but your local
branch and origin will disagree):

  git reset --hard safety/pre-rebase-<branch>

Once satisfied the push is correct and you no longer need the safety net:

  git tag -d safety/pre-rebase-<branch>
---
```

If `mode` was `"lease"`, note in the same "Only if you need to undo this" warning that the
revert must be followed by the same force-with-lease push (using a freshly recomputed
`expect_sha`, not the one from this now-stale decision) to resync. The safety tag is never
deleted automatically here either way -- the user deletes it whenever satisfied, exactly
as before this automation existed.

---

## Failure modes and recovery

| Failure | Recovery |
|---|---|
| Dirty working tree (exit 10) | Stash or commit, then re-run |
| Detached HEAD (exit 11) | Check out a named branch, then re-run |
| On main/master (exit 12) | Check out the correct feature branch |
| Merge commits in range (exit 13) | Refuse; suggest `git rebase --onto` manually |
| No commits in range (exit 20) | Nothing to do |
| Safety tag or tmp branch collision (exit 30/31) | Resolve or delete the stale ref, then re-run (a tag already at this run's own `head_sha` does not collide -- exit 30 only fires for a tag pointing elsewhere) |
| Commit failure during group commit (exit 32) | Fix and retry / skip the hook with `APPLY_PLAN_NO_VERIFY=1` / abort via `bash "$LIB_DIR/abort-plan.sh" "$RUN_DIR"` -- see "Recovery choice" above |
| Tree verification fails (exit 33) | Same three-way choice as exit 32; on abort, `abort-plan.sh` deletes the safety tag too, since it's redundant (branch sha == tag sha) |
| Duplicate file across groups (exit 34) | Fix `plan.json` (or re-run planning) so each file appears in exactly one group, then re-run |
| Branch moved externally, compare-and-swap failed (exit 35) | Same three-way choice as exit 32/33, **except** abort must not delete the safety tag -- it is the only remaining record of the pre-rebase head once the branch has moved. `abort-plan.sh` handles this automatically by comparing shas rather than assuming; never substitute a manual `git reset --hard safety/pre-rebase-<branch>` here, it would discard the very external change that caused the failure |
| plan.json omits a changed path (exit 36) | Add the missing path(s) to the appropriate group in `plan.json` (or re-run planning), then re-run. Common cause: a rename of a file that already existed before the branch -- both the old and new path must be covered |
| Base moved since capture (exit 37) | Re-run Phase 1 (`git-state.sh`) to recapture, then re-plan (Phase 2-3), before retrying apply |
| Process interrupted mid-execute | `bash "$LIB_DIR/abort-plan.sh" "$RUN_DIR"` if HEAD is still on the tmp branch; the safety tag always survives until deleted (by the user, or by `abort-plan.sh` when redundant) |
| Ran `git reset --hard safety/pre-rebase-<branch>` after already pushing | `git reset --hard origin/<branch>` to resync local to what's on origin (verify with `git status` and `git log --oneline origin/<branch>..HEAD` first) |
