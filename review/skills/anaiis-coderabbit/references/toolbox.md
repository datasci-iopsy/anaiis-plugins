# anaiis-coderabbit: Tools, Agents, Phases, Integrations

Loaded on demand from SKILL.md's mode router. Operational reference only; the
authoritative phase procedures live in `phases.md` and `pr-mode.md`.

## Tool usage

- `Bash(git:*)` and `Bash(git -C *:*)` for all git operations
- `Bash(git push origin *:*)` for pushing committed fixes (never to main or master)
- `Bash(coderabbit:*)` for CLI review and auth (local mode only)
- `Bash(gh:*)` for PR comment fetch, auth check, and skip-explanation replies (PR mode only)
- `Bash(jq:*)` for NDJSON parsing
- `Bash(uv:*)` for running `lib/parse-pr-comments.py`
- `Bash(bash lib/reply-skip.sh:*)` for posting a skip-explanation reply to a finding's thread (PR mode only)
- `Bash(bash lib/fetch-thread-state.sh:*)` for fetching review-thread resolution state via GraphQL (PR mode only)
- `Bash(bash lib/run-review.sh:*)` for running `coderabbit review --agent` and parsing normalized NDJSON (local mode Phase 3)
- `Bash(bash lib/fetch-pr-findings.sh:*)` for fetching and normalizing PR findings via `gh` and `lib/parse-pr-comments.py` (PR mode Phase 2')
- `Bash(bash lib/detect-tests.sh:*)` for identifying the project test command (Phase 5)
- `Bash(bash lib/intent-preflight.sh:*)` for running the intent verification preflight check before the intent-verifier agent (Phase 5)
- `Bash(bash lib/review-round.sh:*)` for running a review round with a deterministic timeout and one free retry (Phase 3 and Phase 7)
- `Bash(uv:*)`, `Bash(Rscript:*)`, `Bash(bun:*)`, `Bash(npm:*)` for test verification
- `Grep`, `Glob`, `Read` for codebase inspection during triage
- `Agent(subagent_type="code-surgeon", description="Fix CR-<N>: <summary>")` for surgical fixes
- `Agent(subagent_type="coderabbit-triage", description="Triage CR-<N>: <summary>")` for severity-3 judgment calls
- `Agent(subagent_type="intent-verifier", description="Verify intent CR-<N>: <summary>")` for post-fix intent verification (sev 4-5 and judgment-call sev-3)

Agent definitions live at:
- Plugin-level: `review/agents/code-surgeon.md`, `review/agents/coderabbit-triage.md`, `review/agents/intent-verifier.md`

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
| 3' | Idempotency filter | Drop already-handled IDs via `lib/ledger.sh`, then GitHub-resolved/outdated threads via `lib/fetch-thread-state.sh` (fails open) |
| 4-6 | (shared) | Same as local mode; PR-mode skips also post a reply to the finding's thread via `lib/reply-skip.sh` |
| 7' | Exit | Push committed fixes (guarded); print exit summary |

## Smoke test coverage

`bash lib/smoke.sh` runs S1-S12: normalizer fixture, ledger idempotency and corrupt-file
tolerance, severity inference table, gh wiring check, agent contract drift and
untrusted-input sentinels, intent-preflight fixture checks (S6), intent-verifier contract
(S7), review-round.sh timeout+retry (S8), ledger_intent_verified sequencing guard (S9),
run-review.sh error-event handling and severity mapping (S10), reply-skip.sh source guard
and gh POST wiring (S11), fetch-thread-state.sh GraphQL flattening (S12). Set
`INTENT_JUDGMENT_SMOKE=1` for S7's manual verification scenario.

## Integration

- `/anaiis-gitrebase`: run after this skill to consolidate CR fix commits.
- `/anaiis-changelog`: run after rebase to generate a PR description.
- `/anaiis-gitpr`: run after changelog to open the PR.
- `lib/detect-tests.sh`: called during Phase 5 to identify the project test command.
- `lib/ledger.sh`: shared ledger helpers sourced by phases and lib scripts.
- `lib/review-round.sh`: called during Phase 3 and Phase 7 to run a review round with a deterministic timeout and one free retry.
- `lib/reply-skip.sh`: called from Phase 4's skip branches in PR mode to post a skip-explanation reply on the finding's GitHub thread.
- `lib/fetch-thread-state.sh`: called during Phase 3' to drop findings whose review thread is already resolved or outdated on GitHub.
