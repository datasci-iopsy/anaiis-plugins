---
name: rebase
description: "Explicit /anaiis-git-ops:rebase, rebase commits into logical groups before PR review"
user-invocable: true
trigger: manual
version: 0.3.0
---

# Git Rebase (Branch Reconstruction)

Script-driven branch reconstruction: bash owns every deterministic step, the
rebase-planner agent only refines the commit grouping. Never `git rebase -i`. A bare
`git push --force`/`-f` is never executed or even constructed, anywhere, by any script
this skill runs. `git push --force-with-lease` (explicit form only) may be run directly
by Claude in Phase 6, once, only for the branch and sha this exact run just
tree-verified -- see Phase 6 and Hard limits below for how that push is decided vs.
executed, and why that split matters.

## Scope

```text
$ARGUMENTS: [branch] [base] [--dry-run] [--confirm]
```

- `branch`: feature branch to rebase (default: current branch)
- `base`: base ref to rebase onto (default: `main`)
- `--dry-run`: phases 0-3 only; print the plan, do not execute
- `--confirm`: pause for explicit approval after phase 3, before any destructive work

Runs end-to-end without pausing by default -- the invocation is the authorization. Add
`--confirm` to gate execution on plan approval instead.

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
| 4-5 | `lib/apply-plan.sh` | safety tag, tmp branch, per-group commit, tree-equality verify, swap, `result.json` | hook failure, non-empty diff, or external branch move (tag + tmp preserved; human chooses fix-and-retry / skip-hook / abort via `lib/abort-plan.sh`) |
| 6 | `lib/publish.sh` + main thread | decide plain vs. lease push, then Claude runs the printed command directly (or falls back to a manual hand-off) | `publish.sh` refuses, or the push is denied/fails |

## Hard limits

- Never execute or construct a bare `git push --force`/`-f`, in any script or directly.
  `lib/publish.sh` enforces this structurally: it never invokes `git push` itself and
  never builds such a command, only ever `-u <remote> <branch>` (no existing remote ref)
  or the explicit `--force-with-lease=<branch>:<sha>` form (existing ref, pinned to the
  sha `git ls-remote` just reported, not the local remote-tracking ref).
- The lease push, when decided, is executed by Claude directly as its own Bash call, not
  from inside `publish.sh` -- putting it inside the script would launder it past the
  `settings.json` deny rule, since the permission matcher only inspects the literal
  top-level command, not what a called script does internally. Expect this call to be
  denied until that deny rule is separately narrowed; on denial or failure, fall back to
  the manual hand-off (Phase 6) rather than retrying with a different flag.
- Never push (plain or lease) to `main`/`master`, the remote's resolved default branch, or
  a `run_dir` whose recorded `repo_root` doesn't match the current repo -- `publish.sh`
  refuses all three before deciding a command.
- Never proceed past phase 4-5 if `lib/apply-plan.sh` exits non-zero. For exit 32/33/35,
  the human chooses fix-and-retry, skip-a-hook (`APPLY_PLAN_NO_VERIFY=1`, only with
  explicit approval), or abort (`lib/abort-plan.sh`) -- never automatic on failure
  detection; only the *execution* of a chosen abort is automated. For every other
  non-zero exit, report its recovery command verbatim.
- Never use `git rebase -i`.
- Never delete the safety tag directly -- `lib/abort-plan.sh` may delete it, but only
  when provably redundant (branch sha == tag sha); otherwise the user deletes it when
  satisfied.
- Maximum 10 logical commit groups (enforced by the planner agent).
- `--confirm` gates both the plan review (Phase 3, as before) and the Phase 6 push
  prompt -- no new flag, no reinterpretation beyond "if you asked to review the plan,
  you also get asked before the push runs." Without `--confirm`, both proceed
  automatically, same as today.

## Integration

- `/anaiis-git-ops:changelog`: after rebase, run to generate a PR description from the clean commit history.
