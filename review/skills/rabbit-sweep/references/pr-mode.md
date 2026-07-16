# rabbit-sweep: PR Mode Phase Detail

Applies when invoked as `/anaiis-review:rabbit-sweep --pr <N>`. Replaces Phases 1-3 of local mode.
Phases 4-6 (triage, verify, commit) run verbatim from `phases.md`.

---

## Phase 0: Resolve PR

```bash
gh repo view --json nameWithOwner --jq '.nameWithOwner'
gh pr view <N> --json headRefName,headRefOid,state
```

Hard stops:
- `<N>` is not a positive integer: exit with error.
- `gh auth status` fails: stop. Tell the user to run `gh auth login`.
- PR state is not `OPEN`:
  - **Without `auto`/`all`:** warn the user; confirm before proceeding.
  - **With `auto`/`all`:** hard stop. Print the PR state and exit non-zero; do not proceed against a closed or merged PR unattended.
- Local branch does not match PR `headRefName`: hard stop. Tell the user to check out the PR branch first.

Print resolved context:
```
PR mode:
  PR:      #<N>
  Repo:    <owner/repo>
  Branch:  <headRefName>
  SHA:     <headRefOid[:8]>
```

Export `REPO`, `PR_NUM`, `PR_BRANCH` for use in subsequent phases.

---

## Phase 1': Preflight (PR mode)

Run the shared branch guard, same as local mode Phase 1:

```bash
bash lib/branch-guard.sh
```

On non-zero exit, relay its stderr message verbatim and stop.

Skip the `coderabbit auth` check (not needed for PR mode). `gh auth` was already verified in Phase 0.

---

## Phase 2': Fetch and normalize

Initialize the run ledger (use `lib/ledger.sh`):

```bash
source lib/ledger.sh
ledger_init "$PR_BRANCH" "PR-${PR_NUM}" "pr"
```

Fetch raw comments:

```bash
FETCH_OUT=~/.claude/rabbit-sweep/runs/pr-${PR_NUM}
bash lib/fetch-pr-findings.sh "$REPO" "$PR_NUM" "$FETCH_OUT"
```

Normalize to NDJSON:

```bash
REVIEW_OUT=~/.claude/rabbit-sweep/runs/review-latest.ndjson
uv run lib/parse-pr-comments.py "$PR_NUM" \
    "${FETCH_OUT}/pr-inline.json" \
    "${FETCH_OUT}/pr-summary.json" \
    "$REVIEW_OUT"
```

If `$REVIEW_OUT` is empty or has zero lines: report "No CodeRabbit comments found on PR #<N>." and exit.

---

## Phase 3': Idempotency filter

Two filter stages. Stage 1 drops findings this skill already handled (local ledger); stage 2
drops findings a human already handled on GitHub (thread resolution state). The ledger is the
source of truth for what the skill did; GitHub thread state is the source of truth for what
humans did.

### Stage 1: Ledger filter

Load handled IDs from prior ledgers for this PR:

```bash
source lib/ledger.sh && ledger_resume
HANDLED=$(ledger_handled_ids "$PR_NUM")
```

Filter `$REVIEW_OUT` to new findings only:

```bash
NEW_OUT=~/.claude/rabbit-sweep/runs/review-new.ndjson
while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r '.id')
    if ! printf '%s\n' "$HANDLED" | grep -qxF "$id"; then
        printf '%s\n' "$line"
    fi
done < "$REVIEW_OUT" > "$NEW_OUT"
```

### Stage 2: Thread-resolution filter

Fetch thread state (GraphQL; REST does not expose it). This filter fails open: on any
fetch failure, warn loudly and continue with ledger-only filtering, degrading to stage-1
behavior only.

```bash
THREAD_STATE="${FETCH_OUT}/thread-state.json"
ts_code=0
bash lib/fetch-thread-state.sh "$REPO" "$PR_NUM" "$THREAD_STATE" || ts_code=$?
if [ "$ts_code" -ne 0 ]; then
    printf 'WARNING: thread-state fetch failed (exit %s); continuing with ledger-only filtering.\n' "$ts_code"
    printf 'Findings resolved manually on GitHub may be re-triaged this run.\n'
    printf '[]' > "$THREAD_STATE"
fi
```

Drop findings whose comment sits in a resolved or outdated thread:

```bash
FINAL_OUT=~/.claude/rabbit-sweep/runs/review-active.ndjson
while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r '.id')
    cid="${id##*-}"
    if jq -e --argjson cid "$cid" \
        'any(.[]; .comment_id == $cid and (.is_resolved or .is_outdated))' \
        "$THREAD_STATE" >/dev/null; then
        continue
    fi
    printf '%s\n' "$line"
done < "$NEW_OUT" > "$FINAL_OUT"
```

`pr-summary` findings never appear in review threads, so they pass through unaffected.
Findings dropped here get no ledger event and no reply: nothing was decided by this skill,
and the thread already carries its own resolution. This is deliberate; a user can un-resolve
a thread in the GitHub UI to force it back into triage on the next run.

### Count and report

```
PR #<N>: <total> findings total, <handled> already handled (ledger),
<resolved> resolved/outdated on GitHub, <new> new.
```

If `<new>` is 0: print "All findings already addressed. Nothing to do." and exit cleanly.

Replace `$REVIEW_OUT` reference with `$FINAL_OUT` for all subsequent phases.

---

## Reply on skip (PR mode)

Phase 4's two skip branches (severity 1-2 auto-skip and severity-3 judgment skip, both in
`phases.md`) call this step in PR mode only, immediately after `ledger_skip` is logged. All
skips get a reply, regardless of severity; local mode has no GitHub thread and never calls this.

```bash
bash lib/reply-skip.sh "$REPO" "$PR_NUM" "<id>" "<source>" <severity> "<rationale>"
case $? in
    0)  printf '  reply posted to CodeRabbit thread\n' ;;
    10) printf '  no inline thread (summary finding); no reply\n' ;;
    2)  printf '  WARNING: skip logged but reply could not be posted for %s -- review the PR thread manually\n' "<id>" ;;
    1)  printf '  WARNING: reply-skip.sh usage error for %s\n' "<id>" ;;
esac
```

`REPO` and `PR_NUM` were exported in Phase 0. `<source>` and `<severity>` come from the
finding being triaged; `<rationale>` is the same skip rationale just logged via `ledger_skip`.

`lib/reply-skip.sh` no-ops (exit 10) for `pr-summary` findings, since the auto-generated
walkthrough comment has no real review-comment thread to reply into -- only `pr-inline`
findings get a posted reply.

A reply failure (exit 1 or 2) is non-fatal: print the warning and continue triaging the next
finding. The skip is already recorded in the local ledger regardless of whether the reply
posts, so no audit information is lost; only the GitHub-visible explanation is missing, and
the warning tells the user to check manually. Re-runs never double-post: `ledger_skip` is
terminal, so Phase 3's idempotency filter drops the finding before Phase 4 sees it again.

---

## Phase 7': Exit (PR mode)

After Phase 6 (commit), push committed fixes so the CodeRabbit bot can see them on the next review pass. Do not re-run `coderabbit review`.

### Push

Run the safety check:

```bash
BRANCH=$(git branch --show-current)
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
    printf 'ERROR: refusing to push from %s\n' "$BRANCH"
    exit 1
fi
```

Print what is being pushed, then push:

```bash
if git rev-parse --verify -q "origin/${BRANCH}" >/dev/null; then
    PENDING=$(git log "origin/${BRANCH}..HEAD" --oneline)
else
    PENDING=$(git log HEAD --not --remotes --oneline)
    printf '\nNo origin/%s ref found (branch not yet pushed).\n' "$BRANCH"
fi

PUSHED=false
PUSH_FAILED=false
if [ -n "$PENDING" ]; then
    COUNT=$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')
    printf '\nPushing %s commit(s) to origin/%s:\n' "$COUNT" "$BRANCH"
    printf '%s\n' "$PENDING"
    if git push origin "$BRANCH"; then
        PUSHED=true
    else
        PUSH_FAILED=true
    fi
else
    printf '\nNo commits to push (already up to date).\n'
fi
```

If `git push` fails, `PUSH_FAILED` is set to `true` and the exit summary reports it instead of claiming success. Do not abort; continue to the exit summary.

### Exit summary

```
PR mode complete.
  Fixed and committed: <N>
  Skipped (1-2):       <N>
  Reverted (fail):     <N>
  Fixed without tests: <N>  (no_tests events; verified by intent check only)
```

Then one of, based on `$PUSHED` / `$PUSH_FAILED` / `$PENDING`:
- `$PUSHED = true`:
  ```text
  Pushed to origin/<branch>. CodeRabbit bot will re-review shortly.
  When the bot posts new comments, run:
    /anaiis-review:rabbit-sweep --pr <N>
  ```
- `$PUSH_FAILED = true`:
  ```text
  Push to origin/<branch> failed. Commits remain local; run `git push origin <branch>` manually, then re-run this skill.
  ```
- otherwise (`$PENDING` empty, nothing to push):
  ```text
  No new commits to push this session.
  ```

Do not open or modify the PR. Exit.

---

## Failure modes (PR mode)

| Failure | Recovery |
|---|---|
| gh not authenticated | `gh auth login`, then re-run |
| PR branch mismatch | `git checkout <headRefName>`, then re-run |
| No bot comments yet | Wait for CodeRabbit CI to finish, then re-run |
| parse-pr-comments.py fails | Check `uv` is available; run `uv run lib/parse-pr-comments.py --help` |
| fetch-thread-state.sh fails | Non-fatal: Phase 3' warns and falls back to ledger-only filtering; findings resolved manually on GitHub may be re-triaged that run |
| All findings already handled | Nothing to do; Phase 3' exits before Phase 7' (push) runs, so nothing is pushed |
| Push fails | Commits remain local; run `git push origin <branch>` manually |
