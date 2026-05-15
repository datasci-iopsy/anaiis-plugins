---
name: anaiis-gitrebase
description: "Explicit /anaiis-gitrebase, rebase commits into logical groups before PR review"
user-invocable: true
trigger: manual
version: 0.1.0
---

# Git Rebase (Branch Reconstruction)

Reorganize commits on a feature branch into clean, logically grouped commits for PR review. Uses branch reconstruction instead of `git rebase -i` -- avoids the interactive editor entirely. Claude never force-pushes; the final step hands the user the exact command to run.

## Scope

```
$ARGUMENTS: [branch] [base] [--dry-run]
```

- `branch`: feature branch to rebase (default: current branch)
- `base`: base ref to rebase onto (default: `main`)
- `--dry-run`: run phases 1 and 2 only; output proposed grouping without executing

Examples:
- `/anaiis-gitrebase`
- `/anaiis-gitrebase feature/my-branch main`
- `/anaiis-gitrebase --dry-run`

## Tool usage

- `Bash(git:*)` for all git operations (pre-approved, no permission overhead)
- `Grep`/`Glob` only when file purpose is ambiguous from its path alone
- Never use `Read` to examine file contents for grouping decisions; `--stat` and `--name-only` output is sufficient

**Working directory:** All git commands must start with `git`. If the current shell cwd is not the repo root, use `git -C <absolute-repo-root> <subcommand>` -- never `cd <path> && git <subcommand>`.

## Phase overview

Load `references/phases.md` when a phase begins.

| Phase | Name | Gate |
|---|---|---|
| 1 | Preflight | Clean tree, no merges, named branch |
| 2 | Analysis | Propose commit groupings |
| GATE 1 | User confirms grouping | Must get explicit approval |
| 3 | Execute | Build temp branch with clean commits |
| 4 | Verify | Empty diff confirms tree equality |
| GATE 2 | User confirms verification | Must get explicit approval |
| 5 | Swap | Reset original branch to temp |
| 6 | Hand off | Surface push command; Claude does not push |

## Hard limits

- Never execute `git push --force`, `git push --force-with-lease`, or any force-push variant. Human-only action.
- Never proceed past Phase 4 if the tree diff is non-empty.
- Never start without a clean working tree.
- Never operate on a range that includes merge commits.
- Never delete the safety tag -- the user deletes it when satisfied.
- Never use `git rebase -i`.
- Maximum 10 logical commit groups. If more are needed, suggest splitting the PR.

## Integration

- `anaiis-changelog`: after rebase, run to generate a PR description from the clean commit history.
- `anaiis-preflight`: not needed; this skill does its own git-state preflight in Phase 1.
