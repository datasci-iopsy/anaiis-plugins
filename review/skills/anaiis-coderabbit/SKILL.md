---
name: anaiis-coderabbit
description: "CLI-driven CodeRabbit triage in two modes: (1) local pre-PR via coderabbit review --agent; (2) post-PR via gh api against bot comments. Triages by severity, fixes 3-5 with code-surgeon, verifies with two-stage check (tests + intent), commits, and pushes committed fixes with branch safety guards."
user-invocable: true
trigger: manual
version: 0.2.5
---

# anaiis-coderabbit: CLI-Driven CodeRabbit Triage

Two modes, one triage loop:

- **Local mode** (no args): runs `coderabbit review --agent` against the current branch, triages NDJSON findings, fixes severity 3-5, verifies, commits. Use before opening a PR.
- **PR mode** (`--pr <N>`): fetches CodeRabbit bot comments from GitHub PR #N via `gh api`, normalizes to the same finding shape, then runs the same triage/fix/commit loop. Use after the bot has reviewed your draft PR.

Both modes share Phases 4-6 (triage, two-stage verify, commit). Verification is two-stage: (1) project tests must pass, then (2) a deterministic preflight and, for sev 4-5 and judgment-call sev-3 findings, an intent-verifier agent confirm the edit addresses the finding's stated concern. Both modes push committed fixes with a branch safety guard (never main or master, never force-push).

## Arguments

```
$ARGUMENTS: [--pr <number>] [--base <branch>] [--type <all|committed|uncommitted>] [--dir <path>]
```

- `--pr <N>`: GitHub PR number. Switches to PR mode. Mutually exclusive with `--base`/`--type`.
- `--base <branch>`: override base branch for local mode (default: auto-detected parent or `main`).
- `--type`: review scope for local mode (default: `all`).
- `--dir`: limit review to a subdirectory (local mode only).

Examples:
- `/anaiis-coderabbit`
- `/anaiis-coderabbit --base main`
- `/anaiis-coderabbit --pr 7`

## Tool usage

- `Bash(git:*)` and `Bash(git -C *:*)` for all git operations
- `Bash(git push origin *:*)` for pushing committed fixes (never to main or master)
- `Bash(coderabbit:*)` for CLI review and auth (local mode only)
- `Bash(gh:*)` for PR comment fetch, auth check, and skip-explanation replies (PR mode only)
- `Bash(jq:*)` for NDJSON parsing
- `Bash(uv:*)` for running `lib/parse-pr-comments.py`
- `Bash(bash lib/reply-skip.sh:*)` for posting a skip-explanation reply to a finding's thread (PR mode only)
- `Bash(uv:*)`, `Bash(Rscript:*)`, `Bash(bun:*)`, `Bash(npm:*)` for test verification
- `Grep`, `Glob`, `Read` for codebase inspection during triage
- `Agent(subagent_type="code-surgeon", description="Fix CR-<N>: <summary>")` for surgical fixes
- `Agent(subagent_type="coderabbit-triage", description="Triage CR-<N>: <summary>")` for severity-3 judgment calls
- `Agent(subagent_type="intent-verifier", description="Verify intent CR-<N>: <summary>")` for post-fix intent verification (sev 4-5 and judgment-call sev-3)

Agent definitions live at:
- Plugin-level: `review/agents/code-surgeon.md`, `review/agents/coderabbit-triage.md`, `review/agents/intent-verifier.md`

## Mode router

If `--pr <N>` is present:
1. Load `references/pr-mode.md` and run Phases 0, 1', 2', 3'.
2. Continue from Phase 4 in `references/phases.md`.
3. Run Phase 7' from `references/pr-mode.md` instead of Phase 7.

If `--pr` is absent:
1. Run Phases 1-7 from `references/phases.md`.

Do not pre-load all phase files. Load the active phase file when that phase begins.

## Phase overview

### Local mode

| Phase | Name | Action |
|---|---|---|
| 1 | Preflight | Branch check, coderabbit auth check |
| 2 | Scope resolution | Resolve base branch, confirm with user |
| 3 | Review | Run `coderabbit review --agent` via `lib/run-review.sh`, parse normalized NDJSON |
| 4 | Triage loop | Skip 1-2, coderabbit-triage for 3, surgeon for 3-5 |
| 5 | Per-fix verification | Tests via `lib/detect-tests.sh`; then `lib/intent-preflight.sh` + intent-verifier for sev 4-5 and judgment sev-3; revert on any failure |
| 6 | Commit | Group fixes, stage by name |
| 7 | Review loop controller | Re-run up to 3 *counted* rounds; a timeout gets one free retry via `lib/review-round.sh` and does not consume a round; exit clean, stalled, at cap, or incomplete |

### PR mode

| Phase | Name | Action |
|---|---|---|
| 0 | Resolve PR | Validate PR number, resolve repo + branch via `gh` |
| 1' | Preflight | Branch check, gh auth check |
| 2' | Fetch and normalize | `lib/fetch-pr-findings.sh` + `lib/parse-pr-comments.py` |
| 3' | Idempotency filter | Drop already-handled IDs via `lib/ledger.sh` |
| 4-6 | (shared) | Same as local mode; PR-mode skips also post a reply to the finding's thread via `lib/reply-skip.sh` |
| 7' | Exit | Push committed fixes (guarded); print exit summary |

## Hard limits

- Never edit files while on `main` or `master`.
- Never `git add -A`, `git add .`, or `--no-verify`.
- Never amend commits.
- Never push to `main` or `master`.
- Never force-push (`--force` or `--force-with-lease`).
- Never auto-chain into `/anaiis-gitrebase`, `/anaiis-changelog`, or `/anaiis-gitpr`.
- Never count more than 3 review *rounds* per session (Round 1 in Phase 3; Rounds 2-3 in Phase 7). A round only counts when the review actually returns a result; `lib/review-round.sh` gives one free retry on a timeout before a round is counted, so raw `coderabbit review` invocations can exceed 3.
- Never re-fetch PR comments more than twice per session.
- Never remove the JSONL run ledger during the session.
- In PR mode, `gh api` writes are limited to posting skip-explanation replies via `lib/reply-skip.sh`. Never edit, resolve, or delete existing comments; never reply to `pr-summary` (walkthrough) threads.
- Post at most one skip reply per finding per session (enforced by the Phase 3' already-handled filter, not by `reply-skip.sh` itself).

## Verification

```bash
bash lib/smoke.sh
```

Runs S1-S11: normalizer fixture, ledger idempotency, severity inference table, gh wiring check, agent contract drift, intent-preflight fixture checks (S6), intent-verifier contract (S7), review-round.sh timeout+retry (S8), ledger_intent_verified sequencing guard (S9), run-review.sh error-event handling and severity mapping (S10), reply-skip.sh source guard and gh POST wiring (S11). Set `INTENT_JUDGMENT_SMOKE=1` for S7's manual verification scenario.

## Integration

- `/anaiis-gitrebase`: run after this skill to consolidate CR fix commits.
- `/anaiis-changelog`: run after rebase to generate a PR description.
- `/anaiis-gitpr`: run after changelog to open the PR.
- `lib/detect-tests.sh`: called during Phase 5 to identify the project test command.
- `lib/ledger.sh`: shared ledger helpers sourced by phases and lib scripts.
- `lib/review-round.sh`: called during Phase 3 and Phase 7 to run a review round with a deterministic timeout and one free retry.
- `lib/reply-skip.sh`: called from Phase 4's skip branches in PR mode to post a skip-explanation reply on the finding's GitHub thread.
