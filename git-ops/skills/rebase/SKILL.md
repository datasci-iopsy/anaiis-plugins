---
name: rebase
description: "Explicit /anaiis-git-ops:rebase, rebase commits into logical groups before PR review"
user-invocable: true
trigger: manual
version: 0.2.0
---

# Git Rebase (Branch Reconstruction)

Script-driven branch reconstruction: bash owns every deterministic step, the
rebase-planner agent only refines the commit grouping. Never `git rebase -i`.
Claude never force-pushes; the final phase hands the user the exact command.

## Scope

```
$ARGUMENTS: [branch] [base] [--dry-run] [--confirm]
```

- `branch`: feature branch to rebase (default: current branch)
- `base`: base ref to rebase onto (default: `main`)
- `--dry-run`: phases 0-3 only; print the plan, do not execute
- `--confirm`: pause for explicit approval after phase 3, before any destructive work

Examples:
- `/anaiis-git-ops:rebase`
- `/anaiis-git-ops:rebase feature/my-branch main`
- `/anaiis-git-ops:rebase --dry-run`

## Lib resolution

Shared `lib/` is plugin-level, not skill-local: resolve it from this skill's own base
directory (shown in your invocation context) via `<base>/../../lib/<script>.sh`.

## Phase overview

Load `references/phases.md` when a phase begins.

| Phase | Actor | Action | Stop condition |
|---|---|---|---|
| 0 | `lib/preflight.sh` | clean tree, named non-main branch, no merges, upstream state | any check fails |
| 1 | `lib/git-state.sh` | run dir + commits.json, diffstat, diff.patch | no commits in range |
| 2 | `lib/group-commits.sh` | draft-groups.json from conventional prefixes | never |
| 3 | `rebase-planner` agent | plan.json (max 10 groups), print the plan | `--dry-run` ends here; `--confirm` waits; flagged binaries/submodules wait |
| 4-5 | `lib/apply-plan.sh` | safety tag, tmp branch, per-group commit, tree-equality verify, swap | hook failure or non-empty diff (tag + tmp preserved, recovery printed) |
| 6 | main thread | print log + push handoff (plain push, or force-with-lease text if upstream exists) | n/a |

## Hard limits

- Never execute `git push --force`, `git push --force-with-lease`, or any force-push variant. Human-only action.
- Never proceed past phase 4-5 if `lib/apply-plan.sh` exits non-zero; report its recovery command verbatim.
- Never use `git rebase -i`.
- Never delete the safety tag -- the user deletes it when satisfied.
- Maximum 10 logical commit groups (enforced by the planner agent).

## Integration

- `/anaiis-git-ops:changelog`: after rebase, run to generate a PR description from the clean commit history.
- `anaiis-preflight`: not needed; this skill's phase 0 does its own git-state preflight.
