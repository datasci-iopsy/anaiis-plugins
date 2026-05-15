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

Initialize the run ledger:

```bash
mkdir -p ~/.claude/anaiis-coderabbit/runs
ISO=$(date -u +%Y%m%dT%H%M%SZ)
BRANCH=$(git branch --show-current)
LEDGER=~/.claude/anaiis-coderabbit/runs/${BRANCH//\//-}-${ISO}.jsonl
echo '{"event":"review_started","branch":"'"$BRANCH"'","base":"'"$BASE"'","ts":"'"$ISO"'"}' > "$LEDGER"
```

Run the review and capture NDJSON output:

```bash
REVIEW_OUT=~/.claude/anaiis-coderabbit/runs/review-latest.ndjson
REVIEW_ERR=~/.claude/anaiis-coderabbit/runs/review-latest.err
coderabbit review --agent --base <resolved-base> --no-color [--type <type>] [--dir <dir>] > "$REVIEW_OUT" 2> "$REVIEW_ERR"
```

Read `$REVIEW_OUT` in full. Parse the NDJSON stream to extract findings. Each finding object will include fields like: `id`, `file` (or `path`), `line` (or `startLine`/`endLine`), `severity` (numeric 1-5 or a label), `title`, `body` (the full finding description), and optionally `suggested_fix`. Adapt to the actual schema in the output.

If the output is empty or contains no findings: report "No findings. Branch is clean against `<base>`." and exit (skip to Phase 7).

If the review command fails (non-zero exit): show the tail of the output and stop. Do not proceed to triage.

---

## Phase 4: Triage loop

For each finding, in severity order (highest first), apply the rubric:

**Severity 1-2 (nitpick / false positive):**
- Do not edit.
- Log the skip with a one-sentence rationale to the ledger:
  ```bash
  echo '{"event":"skip","id":"<id>","severity":<n>,"rationale":"<reason>"}' >> "$LEDGER"
  ```
- Print: `SKIP [<id>] <title> -- <rationale>`

**Severity 3 (judgment call):**
- Read the affected file around the reported line.
- Grep for callers of the affected symbol across the codebase.
- State in one sentence: the implementation cost, the expected benefit, and whether the change aligns with the user's coding practices (surgical precision, no speculation).
- Default decision: **fix**, unless the evidence shows the suggested change introduces complexity that outweighs the benefit or contradicts existing patterns.
- Log decision:
  ```bash
  echo '{"event":"decision","id":"<id>","severity":3,"decision":"fix|skip","rationale":"<one-sentence>"}' >> "$LEDGER"
  ```
- If `fix`: proceed to surgeon spawn below.
- If `skip`: print `SKIP [<id>] <title> -- <rationale>` and continue to next finding.

**Severity 4-5 (real defect / clear improvement):**
- Log decision `fix` immediately, no extra reasoning.
- Proceed to surgeon spawn.

**Surgeon spawn (for all `fix` decisions):**

Spawn an Agent with:
- `subagent_type`: `general-purpose`
- `description`: `Fix CR-<id>: <title>`
- Prompt must include:
  - The finding text (title + body + suggested_fix)
  - The file path and line range
  - Any prior ledger entries for the same file (read from `$LEDGER` via jq)
  - Instruction: apply the minimal fix per `claude/agents/code-surgeon.md` rules. No refactors, no surrounding cleanup, no added comments.

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
- Log: `{"event":"verify_failed","id":"<id>","file":"<file>","reason":"<short summary of failure>"}` to the ledger
- Print: `REVERTED [<id>] <title> -- tests failed: <failure summary>`
- Do not commit this finding. Continue to the next finding.

If tests pass (or `none` returned): mark the finding ready to commit. Log: `{"event":"verified","id":"<id>"}`.

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

## Phase 7: Re-review and exit

Re-run the review against the same base to confirm findings resolved:

```bash
coderabbit review --agent --base <resolved-base> --no-color [--type <type>] [--dir <dir>] > ~/.claude/anaiis-coderabbit/runs/review-recheck.ndjson 2>&1
```

Read the output and report the delta:
- Findings closed (were in round 1, gone in round 2)
- Findings still open (appeared in both rounds; may need a follow-up session)
- New findings introduced by fixes (rare; flag for immediate review)

Print a summary:

```
CodeRabbit triage complete.
  Fixed and committed: <N>
  Skipped (1-2): <N>
  Reverted (verify failed): <N>
  Still open: <N>
  New findings: <N>

Next steps:
  /anaiis-gitrebase   -- consolidate commits into logical groups
  /anaiis-changelog   -- generate PR description from clean history
  /anaiis-gitpr       -- open the PR
```

Skill exits. It does not auto-chain into the next skill.

---

## Failure modes

| Failure | Recovery |
|---|---|
| Not authenticated | `coderabbit auth login`, then re-run `/anaiis-coderabbit` |
| On `main` | Create a branch (`git checkout -b coderabbit/<topic>`), then re-run |
| Review command fails | Show tail of output; check auth or CLI version with `coderabbit --version` |
| Surgeon blocked (callers need attention) | Fix callers manually or in a follow-up commit, then re-run the skill |
| All findings skipped or reverted | Report and exit cleanly; nothing to commit |
| Re-review introduces new findings | Triage them immediately or note for a follow-up session |
