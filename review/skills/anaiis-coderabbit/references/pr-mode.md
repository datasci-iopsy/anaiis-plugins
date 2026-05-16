# anaiis-coderabbit: PR Mode Phase Detail

Applies when invoked as `/anaiis-coderabbit --pr <N>`. Replaces Phases 1-3 of local mode.
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
- PR state is not `OPEN`: warn user; confirm before proceeding.
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

Same hard stops as local mode Phase 1:
- Not in a git repo: exit.
- On `main` or `master`: stop.
- Unrecognized branch pattern: warn and confirm.

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
FETCH_OUT=~/.claude/anaiis-coderabbit/runs/pr-${PR_NUM}
bash lib/fetch-pr-findings.sh "$REPO" "$PR_NUM" "$FETCH_OUT"
```

Normalize to NDJSON:

```bash
REVIEW_OUT=~/.claude/anaiis-coderabbit/runs/review-latest.ndjson
uv run lib/parse-pr-comments.py "$PR_NUM" \
    "${FETCH_OUT}/pr-inline.json" \
    "${FETCH_OUT}/pr-summary.json" \
    "$REVIEW_OUT"
```

If `$REVIEW_OUT` is empty or has zero lines: report "No CodeRabbit comments found on PR #<N>." and exit.

---

## Phase 3': Idempotency filter

Load handled IDs from prior ledgers for this PR:

```bash
source lib/ledger.sh
HANDLED=$(ledger_handled_ids "$PR_NUM")
```

Filter `$REVIEW_OUT` to new findings only:

```bash
NEW_OUT=~/.claude/anaiis-coderabbit/runs/review-new.ndjson
while IFS= read -r line; do
    id=$(printf '%s' "$line" | jq -r '.id')
    if ! printf '%s\n' "$HANDLED" | grep -qxF "$id"; then
        printf '%s\n' "$line"
    fi
done < "$REVIEW_OUT" > "$NEW_OUT"
```

Count and report:

```
PR #<N>: <total> findings total, <handled> already handled, <new> new.
```

If `<new>` is 0: print "All findings already addressed. Nothing to do." and exit cleanly.

Replace `$REVIEW_OUT` reference with `$NEW_OUT` for all subsequent phases.

---

## Phase 7': Exit (PR mode)

After Phase 6 (commit), do not re-run `coderabbit review`. Instead:

Print a commit summary:
```
PR mode complete.
  Fixed and committed: <N>
  Skipped (1-2): <N>
  Reverted (verify failed): <N>

To continue the review loop:
  git push                            -- run this manually after this skill exits
  Wait for CodeRabbit bot to re-review.
  /anaiis-coderabbit --pr <N>         -- pick up new bot comments
```

Do not push from inside this skill. Do not open or modify the PR. Exit.

---

## Failure modes (PR mode)

| Failure | Recovery |
|---|---|
| gh not authenticated | `gh auth login`, then re-run |
| PR branch mismatch | `git checkout <headRefName>`, then re-run |
| No bot comments yet | Wait for CodeRabbit CI to finish, then re-run |
| parse-pr-comments.py fails | Check `uv` is available; run `uv run lib/parse-pr-comments.py --help` |
| All findings already handled | Nothing to do; push and wait for re-review |
