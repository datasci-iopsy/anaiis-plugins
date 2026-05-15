---
name: anaiis-coderabbit
description: "CLI-driven CodeRabbit triage: fetch findings via coderabbit review --agent, fix rated 3-5, verify each fix, commit. Replaces the paste-driven coderabbit-fix workflow."
user-invocable: true
trigger: manual
version: 0.1.0
---

# anaiis-coderabbit: CLI-Driven CodeRabbit Triage

Runs `coderabbit review --agent` against the current branch, triages findings (skip 1-2, fix 3-5), verifies each fix before committing, then re-reviews to confirm findings resolved. No paste, no VS Code, no deferred file.

## Scope

```
$ARGUMENTS: [--base <branch>] [--type <all|committed|uncommitted>] [--dir <path>]
```

- `--base`: override the default base branch (default: auto-detected parent branch or `main`)
- `--type`: review scope passed to the CLI (default: `all`, matching all local changes vs the base)
- `--dir`: limit review to a subdirectory

Examples:
- `/anaiis-coderabbit`
- `/anaiis-coderabbit --base main`
- `/anaiis-coderabbit --base feat/my-feature --type committed`

## Tool usage

- `Bash(git:*)` and `Bash(git -C *:*)` for all git operations
- `Bash(coderabbit:*)` for CLI review and auth
- `Bash(jq:*)` for NDJSON parsing
- `Grep`/`Glob`/`Read` for codebase inspection during triage
- `Agent` (subagent_type=general-purpose, description="Fix CR-<N>: <summary>") for surgical fixes
- `Bash(uv:*)`, `Bash(Rscript:*)`, `Bash(bun:*)`, `Bash(npm:*)` for test verification

All git commands must start with `git` to match pre-approved patterns.

## Phase overview

Load `references/phases.md` when a phase begins. Do not pre-load all phases.

| Phase | Name | Action |
|---|---|---|
| 1 | Preflight | Branch check, auth check |
| 2 | Scope resolution | Resolve base branch, confirm with user |
| 3 | Review | Run `coderabbit review --agent`, parse NDJSON |
| 4 | Triage loop | Skip 1-2, fix 3-5 via surgeon agents |
| 5 | Per-fix verification | Run tests, revert on failure |
| 6 | Commit | Group fixes, stage by name |
| 7 | Re-review and exit | Confirm findings closed |

## Hard limits

- Never edit files while on `main` or `master`.
- Never `git add -A`, `git add .`, or `--no-verify`.
- Never amend commits.
- Never auto-chain into `/anaiis-gitrebase`, `/anaiis-changelog`, or `/anaiis-gitpr`.
- Never remove the JSONL run ledger during the session.
- Never run `coderabbit review` a third time in the same session.

## Integration

- `/anaiis-gitrebase`: run after this skill to consolidate CR fix commits.
- `/anaiis-changelog`: run after rebase to generate a PR description.
- `/anaiis-gitpr`: run after changelog to open the PR.
- `lib/detect-tests.sh`: called during Phase 5 to identify the project test command.
