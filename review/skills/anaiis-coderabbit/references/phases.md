# anaiis-coderabbit: Phase Detail

## Phase 1: Preflight (read-only, hard stops before any review runs)

Run as a single chained Bash call:

```bash
git status --porcelain && git branch --show-current && git rev-parse --show-toplevel
```

**Hard stops -- do not proceed if:**

- **Not in a git repo:** exit with error.
- **On `main` or `master`:** stop. Tell the user to create a branch first. Remind them of the `coderabbit/<topic>` convention from `rules/git.md`. Do not bypass.
- **Branch does not match `claude/*`, `coderabbit/*`, or a user feature-branch pattern (`feat/*`, `fix/*`, `hotfix/*`, `chore/*`):** warn, confirm with user before continuing.

Check auth:

```bash
coderabbit auth status --agent | jq -e '.authenticated == true'
```

If this fails (exit non-zero or returns false): stop and tell the user to run `coderabbit auth login`. Do not proceed without verified auth.

---

## Phase 2: Scope resolution

Determine the base for the review:

1. If `--base` was passed, use that value directly.
2. Otherwise, find the parent branch:
   ```bash
   git log --oneline --simplify-by-decoration --decorate=short HEAD~20 | head -5
   ```
   Use the first ref that differs from the current branch and matches `main`, `master`, or a user feature-branch pattern. If ambiguous, ask the user.

Resolve and print the review scope before running:

```
Review scope:
  Branch:  <current-branch>
  Base:    <resolved-base>
  Type:    <all|committed|uncommitted>
  Dir:     <path or "repo root">

Confirm to proceed? (the review call may take 30-90 seconds)
```

Wait for user confirmation.

---

## Phase 3: Review

Initialize the run ledger and round counter using `lib/ledger.sh`:

```bash
source lib/ledger.sh
BRANCH=$(git branch --show-current)
ledger_init "$BRANCH" "$BASE" "local"
ROUND=1
```

Run the review via the `lib/run-review.sh` wrapper, which captures and normalizes NDJSON output to the shared finding schema:

```bash
REVIEW_OUT=~/.claude/anaiis-coderabbit/runs/review-latest.ndjson
REVIEW_ERR=~/.claude/anaiis-coderabbit/runs/review-latest.err
bash lib/run-review.sh "$BASE" [--type <type>] [--dir <dir>] > "$REVIEW_OUT" 2> "$REVIEW_ERR"
```

Each line of `$REVIEW_OUT` is a finding with fields: `id`, `file`, `line`, `severity` (1-5), `title`, `body`, `suggested_fix` (or null), `source` ("cli").

If the output is empty or contains no findings: report "No findings. Branch is clean against `<base>`." and exit (skip to Phase 7).

If the review command fails (non-zero exit): show the tail of the output and stop. Do not proceed to triage.

---

## Phase 4: Triage loop

For each finding, in severity order (highest first), apply the rubric:

**Severity 1-2 (nitpick / false positive):**
- Do not edit.
- Log the skip:
  ```bash
  ledger_skip "<id>" <n> "<rationale>"
  ```
- Print: `SKIP [<id>] <title> -- <rationale>`

**Severity 3 (judgment call):**
- Spawn `Agent(subagent_type="coderabbit-triage", description="Triage CR-<id>: <title>")` with the finding body, file, line, and suggested_fix. The agent returns a single-line JSON verdict: `{"decision": "skip|fix", "rationale": "<one sentence>"}`.
- Use that verdict for the decision. Log it:
  ```bash
  ledger_decision "<id>" 3 "<decision>" "<rationale>"
  ```
- If `fix`: proceed to surgeon spawn below.
- If `skip`: print `SKIP [<id>] <title> -- <rationale>` and continue to next finding.

**Severity 4-5 (real defect / clear improvement):**
- Log decision fix immediately, no extra reasoning:
  ```bash
  ledger_decision "<id>" <n> "fix" "severity <n>: fix without triage"
  ```
- Proceed to surgeon spawn.

**Surgeon spawn (for all `fix` decisions):**

Spawn an Agent with:
- `subagent_type`: `code-surgeon`
- `description`: `Fix CR-<id>: <title>`
- Prompt must include:
  - The finding text (title + body + suggested_fix)
  - The file path and line range
  - Any prior ledger entries for the same file (read from `$LEDGER` via jq)
  - Instruction: apply the minimal fix. No refactors, no surrounding cleanup, no added comments.

After the surgeon completes, proceed to Phase 5 immediately before triaging the next finding.

---

## Phase 5: Per-fix verification

Immediately after each surgeon completes:

**Identify what changed:**
```bash
git diff --name-only HEAD
```

**Detect and run tests:**
```bash
DETECT=lib/detect-tests.sh
if [ -x "$DETECT" ]; then
    bash "$DETECT"
else
    echo "none"
fi
```

This script prints the test command(s) for the project, one per line, or `none` if no test suite is detected. Run each command. If any command exits non-zero:
- Revert the fix: `git restore <file>`
- Log: `ledger_verify_failed "<id>" "<file>" "<short summary of failure>"`
- Print: `REVERTED [<id>] <title> -- tests failed: <failure summary>`
- Do not commit this finding. Continue to the next finding.

If tests pass (or `none` returned): log `ledger_verified "<id>"` (intermediate: tests passed, intent check pending), then run the deterministic preflight:

```bash
preflight_reason=""
if ! preflight_reason=$(bash lib/intent-preflight.sh "<finding.file>" <line_start> <line_end> 2>&1); then
    ledger_intent_failed "<id>" "<finding.file>" "$preflight_reason"
    git restore "<finding.file>"
    # Print: REVERTED [<id>] <title> -- preflight failed: <preflight_reason>
    # Continue to next finding.
fi
ledger_intent_verified "<id>"
```

`intent-preflight.sh` checks three things: (1) the surgeon edited the named file (diff non-empty), (2) at least one hunk overlaps the finding's line range within a ±20-line window, and (3) the diff contains at least one non-comment, non-whitespace line. On any failure it exits 1 with a `preflight:<code>` reason on stderr.

On preflight pass, check whether this finding needs intent verification:

- **Sev 4-5**, or **sev 3 where the triage decision came from `coderabbit-triage`** (a judgment call, recorded in `$LEDGER` as a `decision` event with source `coderabbit-triage`): spawn the verifier.
- **Sev 3 with a mechanical `suggested_fix`** (triage decision logged as `"fix"` without spawning `coderabbit-triage`, meaning the fix was mechanical): skip the verifier and emit `ledger_intent_verified "<id>"` directly.
- **Surgeon returned `Already resolved:`**: emit `ledger_intent_verified "<id>"` directly without preflight or verifier.
- **Surgeon returned `Blocked:`**: no `verified` event; preserve existing behavior.

**Verifier spawn (sev 4-5 or judgment sev-3):**

Spawn an Agent with:
- `subagent_type`: `intent-verifier`
- `description`: `Verify intent CR-<id>: <title>`
- Prompt must include: the finding `body`, `suggested_fix`, and the post-surgeon diff hunk (`git diff HEAD -- <file>`)

The agent returns one line of JSON: `{"intent_met": <true|false>, "rationale": "<one sentence>"}`.

- If `intent_met: true`: log `ledger_intent_verified "<id>"`. The finding is ready to commit.
- If `intent_met: false`: log `ledger_intent_failed "<id>" "<file>" "<rationale>"`, revert `git restore "<file>"`, print `REVERTED [<id>] <title> -- intent failed: <rationale>`, and continue to next finding.

**Rollback path (if verifier proves too aggressive for your codebase):**

If a real run reverts more than ~30% of legitimate fixes, or an adopter reports the 3-round cap hitting on routine work, wrap the verifier spawn in an env-var guard:

```bash
if [[ "${INTENT_VERIFY:-1}" == "1" ]]; then
    # ... preflight + verifier spawn ...
else
    ledger_intent_verified "$id"  # bypass; old behavior
fi
```

Default `INTENT_VERIFY=1` (verifier on). Set `INTENT_VERIFY=0` to restore pre-verifier termination behavior without reverting commits.

Note: formatters (ruff, shfmt, sqlfmt) fire automatically via the PostToolUse hook on every Edit. Treat any hook-reported format changes as already applied.

---

## Phase 6: Commit

After all findings are triaged and verified, group commits by logical concern:

- One finding per commit is the default.
- Cluster only if multiple findings touched the same file with the same logical intent.
- Stage by name only: `git add <file1> <file2> ...`. Never `git add -A` or `git add .`.
- Commit message format: `Fix CR-<id>: <short imperative description>`. No trailing period.
- Never `--no-verify`. Never `--amend`.

Example:
```bash
git add R/analysis.R
git commit -m "Fix CR-4: add na.rm=TRUE to mean() call in score_items"
```

If no findings were successfully verified, report "No commits: all findings were skipped or failed verification." and exit.

---

## Phase 7: Review loop controller

Phase 7 closes the triage cycle and either exits or continues into the next round. Maximum 3 total review invocations per session (Phase 3 is Round 1; each re-review here increments the counter).

### Round tracking

Initialize `ROUND=1` at the start of Phase 3 (after `ledger_init`). Increment here before each re-review. Log each re-review start:

```bash
ROUND=$((ROUND + 1))
ledger_round_start "$ROUND"
```

### Re-review

```bash
printf '\n[Round %s/3] Running local review against %s...  (30-90s)\n' "$ROUND" "$BASE"
REVIEW_RECHECK=~/.claude/anaiis-coderabbit/runs/review-recheck-${ROUND}.ndjson
REVIEW_ERR=~/.claude/anaiis-coderabbit/runs/review-recheck-${ROUND}.err
timeout 180 bash lib/run-review.sh "$BASE" [--type <type>] [--dir <dir>] \
    > "$REVIEW_RECHECK" 2> "$REVIEW_ERR"
EXIT_CODE=$?
```

**If `EXIT_CODE` is 124** (timeout): print `[Round N/3] Review timed out after 180s. Stopping.` and exit non-zero.

**If `EXIT_CODE` is non-zero (other):** print tail of `$REVIEW_ERR` and stop.

### Severity drift check

After parsing `$REVIEW_RECHECK`, warn on any finding where the severity defaulted to 3 but the body contains no known CodeRabbit tag (`critical`, `major`, `minor`, `nitpick`, `potential issue`, `refactor suggestion`). These are candidates for format drift:

```
[Round N/3] Warning: finding <id> has no recognized severity tag. Defaulting to sev-3.
Check coderabbit CLI output format if this is unexpected.
```

### Exit conditions (check in order)

**Condition 1: Clean.** Count sev 3-5 findings in `$REVIEW_RECHECK`. If zero:
- Print clean exit summary (below).
- Exit.

**Condition 2: Stalled.** Findings remain, but every sev 3-5 finding in `$REVIEW_RECHECK` matches a `file`+`line` pair that already has either a `verify_failed` or `intent_failed` event, or a `decision:"fix"` with no subsequent `intent_verified` event in `$LEDGER`. Both `verify_failed` (tests failed) and `intent_failed` (intent check failed) are stall signals: a subsequent surgeon round would face the same barrier. The surgeon cannot make further progress on these findings.
- Print stall exit summary (below).
- Exit.

**Condition 3: Round cap.** `$ROUND` equals 3 and findings remain (not stalled).
- Print round-cap exit summary (below).
- Exit.

**Condition 4: Continue.** Findings remain, not stalled, `$ROUND` < 3.
- Print: `[Round N/3] <count> findings remain at sev 3+. Continuing triage.`
- Set `REVIEW_OUT="$REVIEW_RECHECK"`.
- Return to Phase 4 with the new finding set.

### Push committed fixes

Before printing the exit summary, push any commits that landed this session. Run the safety check first:

```bash
BRANCH=$(git branch --show-current)
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
    printf 'ERROR: refusing to push from %s\n' "$BRANCH"
    exit 1
fi
```

Print what is about to be pushed, then push:

```bash
PENDING=$(git log "origin/${BRANCH}..HEAD" --oneline 2>/dev/null)
if [ -n "$PENDING" ]; then
    COUNT=$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')
    printf '\nPushing %s commit(s) to origin/%s:\n' "$COUNT" "$BRANCH"
    printf '%s\n' "$PENDING"
    git push origin "$BRANCH"
else
    printf '\nNo commits to push (already up to date).\n'
fi
```

If `git push` fails: print the error, note that commits remain local, and continue to the exit summary. Do not abort the skill on push failure.

### Exit summaries

**Clean:**
```
[Round N/3] 0 findings at sev 3+. Branch is clean.

CodeRabbit triage complete.
  Rounds run:                       N
  Fixed and committed:              <total>
  Skipped (sev 1-2):                <total>
  Reverted (verify fail):           <total>
  Reverted (intent fail):           <total>  (<N of M> were sev-3 judgment findings)

Next steps:
  /anaiis-gitrebase   -- consolidate commits into logical groups
  /anaiis-changelog   -- generate PR description from clean history
  /anaiis-gitpr       -- open the PR
```

**Stalled** (surgeon could not fix remaining findings):
```
[Round N/3] Stalled: remaining findings were attempted and could not be fixed automatically.

CodeRabbit triage complete (stalled).
  Rounds run:                       N
  Fixed and committed:              <total>
  Skipped (sev 1-2):                <total>
  Reverted (verify fail):           <total>
  Reverted (intent fail):           <total>  (<N of M> were sev-3 judgment findings)
  Still open:                       <count>

Open findings:
  [<id>] sev=<N>  <file>:<line>  <title>

Address open findings manually, then re-run /anaiis-coderabbit.
```

**Round cap** (3 rounds exhausted, findings remain):
```
[Round 3/3] Round cap reached with <count> findings still open.

CodeRabbit triage complete (cap reached).
  Rounds run:                       3
  Fixed and committed:              <total>
  Skipped (sev 1-2):                <total>
  Reverted (verify fail):           <total>
  Reverted (intent fail):           <total>  (<N of M> were sev-3 judgment findings)
  Still open:                       <count>

Open findings:
  [<id>] sev=<N>  <file>:<line>  <title>

Re-run /anaiis-coderabbit in a new session to continue.
```

Skill exits. It does not auto-chain into the next skill.

---

## Failure modes

| Failure | Recovery |
|---|---|
| Not authenticated | `coderabbit auth login`, then re-run `/anaiis-coderabbit` |
| On `main` | Create a branch (`git checkout -b coderabbit/<topic>`), then re-run |
| Review command fails | Show tail of output; check auth or CLI version with `coderabbit --version` |
| Review times out (code 124) | Network or model latency; wait and re-run |
| Surgeon blocked (callers need attention) | Fix callers manually or in a follow-up commit, then re-run the skill |
| All findings skipped or reverted | Report and exit cleanly; nothing to commit |
| Stall after round N | Fix open findings manually; re-run in a new session |
| Round cap hit | Re-run `/anaiis-coderabbit` in a new session to pick up remaining findings |
| Push fails | Commits remain local; run `git push origin <branch>` manually |
