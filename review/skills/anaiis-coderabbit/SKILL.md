---
name: anaiis-coderabbit
description: "CLI-driven CodeRabbit triage in two modes: (1) local pre-PR via coderabbit review --agent; (2) post-PR via gh api against bot comments. Triages by severity, fixes 3-5 with code-surgeon, verifies tests, commits, and pushes committed fixes with branch safety guards."
user-invocable: true
trigger: manual
version: 0.2.0
---

# anaiis-coderabbit: CLI-Driven CodeRabbit Triage

Two modes, one triage loop:

- **Local mode** (no args): runs `coderabbit review --agent` against the current branch, triages NDJSON findings, fixes severity 3-5, verifies, commits. Use before opening a PR.
- **PR mode** (`--pr <N>`): fetches CodeRabbit bot comments from GitHub PR #N via `gh api`, normalizes to the same finding shape, then runs the same triage/fix/commit loop. Use after the bot has reviewed your draft PR.

Both modes share Phases 4-6 (triage, verify, commit). Both modes push committed fixes with a branch safety guard (never main or master, never force-push).

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
- `Bash(gh:*)` for PR comment fetch and auth check (PR mode only)
- `Bash(jq:*)` for NDJSON parsing
- `Bash(uv:*)` for running `lib/parse-pr-comments.py`
- `Bash(uv:*)`, `Bash(Rscript:*)`, `Bash(bun:*)`, `Bash(npm:*)` for test verification
- `Grep`, `Glob`, `Read` for codebase inspection during triage
- `Agent(subagent_type="code-surgeon", description="Fix CR-<N>: <summary>")` for surgical fixes
- `Agent(subagent_type="coderabbit-triage", description="Triage CR-<N>: <summary>")` for severity-3 judgment calls

Agent definitions live at:
- Plugin-level: `review/agents/code-surgeon.md`
- Skill-local: `agents/coderabbit-triage.md`

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
| 5 | Per-fix verification | Run tests via `lib/detect-tests.sh`, revert on failure |
| 6 | Commit | Group fixes, stage by name |
| 7 | Review loop controller | Re-run up to 3 rounds total; exit clean, stalled, or at cap |

### PR mode

| Phase | Name | Action |
|---|---|---|
| 0 | Resolve PR | Validate PR number, resolve repo + branch via `gh` |
| 1' | Preflight | Branch check, gh auth check |
| 2' | Fetch and normalize | `lib/fetch-pr-findings.sh` + `lib/parse-pr-comments.py` |
| 3' | Idempotency filter | Drop already-handled IDs via `lib/ledger.sh` |
| 4-6 | (shared) | Same as local mode |
| 7' | Exit | Push committed fixes (guarded); print exit summary |

## Hard limits

- Never edit files while on `main` or `master`.
- Never `git add -A`, `git add .`, or `--no-verify`.
- Never amend commits.
- Never push to `main` or `master`.
- Never force-push (`--force` or `--force-with-lease`).
- Never auto-chain into `/anaiis-gitrebase`, `/anaiis-changelog`, or `/anaiis-gitpr`.
- Never run `coderabbit review` more than 3 times per session (Round 1 in Phase 3; Rounds 2-3 in Phase 7).
- Never re-fetch PR comments more than twice per session.
- Never remove the JSONL run ledger during the session.

## Verification

```bash
bash lib/smoke.sh
```

Runs S1-S5: normalizer fixture, ledger idempotency, severity inference table, gh wiring check, agent contract drift.

## Integration

- `/anaiis-gitrebase`: run after this skill to consolidate CR fix commits.
- `/anaiis-changelog`: run after rebase to generate a PR description.
- `/anaiis-gitpr`: run after changelog to open the PR.
- `lib/detect-tests.sh`: called during Phase 5 to identify the project test command.
- `lib/ledger.sh`: shared ledger helpers sourced by phases and lib scripts.
