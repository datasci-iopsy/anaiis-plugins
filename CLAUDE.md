# anaiis-plugins: Claude instructions

Plugin repo for the anaiis Claude Code skill suite (I-O Psychology research workflows).
Five plugins: `review`, `git`, `data`, `writing`, `meta`.

## Workflow

### Plan first
Enter plan mode for any task with 3+ steps or touching 3+ files. Stop and re-plan if something goes sideways.

### Verify before done
Never mark a task complete without proof. For CI-adjacent changes, run the relevant script locally first (see CI below).

### Minimal impact
Touch only what the task requires. One logical concern per commit. No refactors in the same commit as a fix.

### Bug reports
Point at the error, trace to root cause, fix it. No band-aids.

## Repo structure

```
<plugin>/
  skills/          SKILL.md files (auto-discovered by Claude)
  agents/          agent definitions (optional)
  .claude-plugin/
    plugin.json    plugin manifest
.claude-plugin/
  marketplace.json registry of all plugins
scripts/
  lint-skills.py
  count-skill-tokens.py
Makefile           install and smoke targets
```

## CI: validate workflow

The `Validate skills` workflow (`.github/workflows/validate.yml`) runs three checks:

| Step | Script | What it checks |
|---|---|---|
| Lint SKILL.md frontmatter | `scripts/lint-skills.py` | Required frontmatter fields |
| Token budget | `scripts/count-skill-tokens.py --budget 500` | SKILL.md token count (non-blocking) |
| Validate plugin manifests | inline Python | `marketplace.json` sources resolve to real `plugin.json` files |

**Before opening any PR that touches manifests or skills, run locally:**

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

The inline manifest script mirrors the CI step exactly. If it passes locally, CI passes.

## manifest.json field reference

| Field | marketplace.json | plugin.json |
|---|---|---|
| Path to plugin dir | `source` (not `path`) | n/a |
| Skills | auto-discovered from `skills/*/SKILL.md` | no `skills` array |
| Required top-level | `$schema`, `name`, `owner` | `author` object |

## Install

```bash
make install          # sync all plugins to ~/.claude/
make install-<plugin> # sync one plugin
make smoke            # run all lib/smoke.sh scripts
```

## Git

- Claude always verifies and works on a `claude/<topic>` worktree, never on `main` or the user's feature branch.
- Stage files by name. One concern per commit.
- Do not push without explicit instruction.
