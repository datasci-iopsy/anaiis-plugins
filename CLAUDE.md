# anaiis-plugins: Claude instructions

Plugin repo for the anaiis Claude Code skill suite (I-O Psychology research workflows).
Five plugins: `review`, `git`, `data`, `writing`, `meta`. Global behavioral rules live
in `~/.claude/CLAUDE.md` and `~/anaiis-dotfiles/claude/rules/`; this file adds repo-specific
instructions layered on top of those.

---

## Workflow Orchestration

1. **Plan first.** Enter plan mode for any task with 3+ steps or touching 3+ files.
   Stop and re-plan if something goes sideways mid-task.

2. **Subagents are read-only by default.** Use `Explore` for discovery and `Plan` for
   design. Skill edits, file writes, and commits happen in the main thread only.

3. **Verify before done.** For any change to skills, manifests, or CI config, run the
   local validation block (see "Local validation" below) before reporting complete.
   Never mark a task done without proof.

4. **Minimal impact.** Touch only what the task requires. One logical concern per
   commit. No refactors in the same commit as a fix.

5. **Bug reports: no band-aids.** Point at the error, trace to root cause, fix it
   there.

---

## Task Management

- Use `TaskCreate` when a change touches 2+ files or has ordering dependencies. Mark
  items complete as they finish, not in a batch at the end.
- Write a one-line summary at each step. Full review only when the user asks "what did
  you do?"
- Capture corrections into `~/.claude/memory/` when they would apply to future
  sessions. See global memory rules.

---

## Core Principles

### Single Responsibility Principle

Every skill does one thing well. If two skills need shared logic, that logic lives in
a `lib/` script, not duplicated across SKILL.md files.

### Test-Driven Development

When a skill grows logic that can fail silently (parsers, normalizers, ledger writers,
multi-step transforms with branching state), write fixture-based tests in `lib/smoke.sh`
before or alongside the code. `anaiis-coderabbit` is the canonical example of a fully
tested expanded skill.

### Simplicity first

Start every new skill as a single flat `SKILL.md`. Promote to the expanded layout only
when a trigger condition is met (see below).

---

## Skill format: flat vs expanded

| | Flat | Expanded |
|---|---|---|
| Layout | One `SKILL.md`, prose only | `SKILL.md` + `references/`, `lib/`, optional `agents/` |
| When to use | Procedural workflow, no scripts, no deterministic logic to test | Scripts, deterministic transforms, multi-phase flow, or shared logic |
| Tests | None | `lib/smoke.sh` with fixture-based checks |
| Working example | `anaiis-changelog`, `anaiis-copyedit`, `anaiis-preflight` | `anaiis-coderabbit` |

### Decision tree: when to promote flat to expanded

Promote when **any** of the following is true:

1. The skill needs a shell script, a Python parser, or a deterministic transform that
   can produce wrong output silently.
2. The skill duplicates logic already present in another skill in this repo.
3. The skill has more than ~3 phases and `SKILL.md` exceeds the 500-token budget
   checked by `scripts/count-skill-tokens.py`.
4. The skill needs a skill-local agent (one whose knowledge is useless outside this
   skill).

### How to promote

- Move long-form phase detail to `references/phases.md`. SKILL.md becomes the router.
- Create `lib/` for scripts. Every new script gets at least one fixture test in
  `lib/smoke.sh`.
- Create `agents/` only for skill-local agents. Cross-skill agents go in
  `<plugin>/agents/` and are registered in `plugin.json`.

---

## Repo layout

```
<plugin>/
  skills/<skill-name>/
    SKILL.md             skill definition (auto-discovered by Claude Code)
    references/          extended phase docs (expanded skills only)
    lib/                 shell scripts, Python helpers, smoke.sh (expanded only)
    agents/              skill-local agent definitions (optional)
  agents/                plugin-level shared agents
  .claude-plugin/
    plugin.json          plugin manifest
.claude-plugin/
  marketplace.json       registry of all plugins
scripts/
  lint-skills.py         frontmatter linter (run before every PR)
  count-skill-tokens.py  token budget checker (500-token threshold)
.github/workflows/
  validate.yml           CI: frontmatter lint + manifest validation
```

---

## Local validation

Run before any PR that touches skills or manifests:

```bash
python3 scripts/lint-skills.py

python3 - <<'EOF'
import json
from pathlib import Path
repo = Path(".")
errors = []
mkt = repo / ".claude-plugin" / "marketplace.json"
data = json.loads(mkt.read_text())
for plugin in data.get("plugins", []):
    path = repo / plugin["source"] / ".claude-plugin" / "plugin.json"
    if not path.exists():
        errors.append(f"plugin path missing: {path}")
if errors:
    [print(f"FAIL: {e}") for e in errors]
    raise SystemExit(1)
print("All plugin manifests valid.")
EOF
```

This mirrors the CI step exactly.

---

## manifest.json field reference

| Field | marketplace.json | plugin.json |
|---|---|---|
| Path to plugin dir | `source` (not `path`) | n/a |
| Skills | auto-discovered from `skills/*/SKILL.md` | no `skills` array |
| Required top-level | `$schema`, `name`, `owner` | `author` object |

---

## Git

- Work on a `claude/<topic>` branch, never on `main` or the user's feature branch.
- Stage files by name. One concern per commit.
- Do not push without explicit instruction.
- Full git rules defer to `~/anaiis-dotfiles/claude/rules/git.md`.
