# anaiis-plugins

Claude Code skill plugins for research and data science workflows (I-O Psychology).
Five plugins cover the full cycle from data analysis through manuscript review and
git housekeeping.

## What you get

| Plugin | Skills |
|---|---|
| **anaiis-review** | CodeRabbit triage, document audit, manuscript peer review, skill review |
| **anaiis-git** | PR creation, commit rebase, changelog generation, environment preflight |
| **anaiis-data** | DuckDB ad hoc queries, dashboards, web verification, knowledge graphs |
| **anaiis-writing** | Literature review synthesis, manuscript copyediting |
| **anaiis-meta** | Parallel subagent orchestration |

## Install

These plugins are distributed through the Claude Code marketplace. No `git clone`
or local setup is required.

**Step 1.** Add this repo as a known marketplace in `~/.claude/settings.json`:

```json
"extraKnownMarketplaces": {
    "anaiis-plugins": {
        "source": {
            "source": "github",
            "repo": "datasci-iopsy/anaiis-plugins"
        }
    }
}
```

**Step 2.** Enable the plugins you want in the same file:

```json
"enabledPlugins": {
    "anaiis-review@anaiis-plugins": true,
    "anaiis-git@anaiis-plugins": true,
    "anaiis-data@anaiis-plugins": true,
    "anaiis-writing@anaiis-plugins": true,
    "anaiis-meta@anaiis-plugins": true
}
```

Claude Code fetches the skills from GitHub on first use and caches them locally.
To pick up updates after a new release, start a fresh Claude Code session.

## Use

Once installed, invoke skills by name at the prompt:

```
/anaiis-coderabbit              -- triage CodeRabbit findings and fix severity-3+ issues
/anaiis-litreview "topic"       -- synthesize literature from your local catalog
/anaiis-duckdb                  -- query a local CSV, Parquet, or Excel file
/anaiis-gitpr                   -- open a pull request with a structured body
/anaiis-peerreview              -- peer-review a manuscript draft
```

Type `/` in Claude Code to see all available skills with descriptions.

## Requirements

**All plugins:** [Claude Code](https://claude.ai/code) (any plan).

**Per-plugin CLI dependencies** (install only what you use):

| Plugin | CLIs needed |
|---|---|
| anaiis-review | `gh` (GitHub CLI), `coderabbit` CLI |
| anaiis-git | `gh` |
| anaiis-data | `duckdb`, `uv` (for Python scripts), `gh` for web verify |
| anaiis-writing | none beyond Claude Code |
| anaiis-meta | none beyond Claude Code |

Install missing CLIs via Homebrew on macOS:
```bash
brew install gh duckdb
brew install uv            # Python toolchain
npm install -g coderabbit  # CodeRabbit CLI
```

## Optional: integrate with my dotfiles

A companion dotfiles repo (`datasci-iopsy/anaiis-dotfiles`, private) layers additional
behavior on top of these plugins: global behavioral rules, pre-commit hooks,
per-language linting configs, and agent definitions that the skills reference.

**The plugins work without the dotfiles.** The dotfiles add consistency across
machines and stricter local guardrails; they are not required for any skill to run.
If you want the same global setup, reach out or adapt the patterns to your own
dotfiles.

---

## For contributors and developers

### Repo layout

```
<plugin>/
  skills/<skill-name>/
    SKILL.md             skill definition (auto-discovered by Claude Code)
    references/          extended phase docs, for larger skills
    lib/                 shell scripts and Python helpers
    lib/smoke.sh         fixture-based smoke tests (expanded skills only)
    agents/              skill-local agent definitions (optional)
  agents/                plugin-level shared agents
  .claude-plugin/
    plugin.json          plugin manifest
.claude-plugin/
  marketplace.json       registry of all plugins
scripts/
  lint-skills.py         frontmatter linter
  count-skill-tokens.py  token budget checker
.github/workflows/
  validate.yml           CI: lint + manifest validation
```

### Local validation

Before opening any PR that touches skills or manifests, run:

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

This mirrors the CI check exactly. If it passes locally, CI passes.

### Adding or modifying a skill

See `CLAUDE.md` for the skill format rules, SRP guidelines, and the decision tree
for when to promote a flat skill to the expanded layout.

### Branch and PR conventions

- Work on a `claude/<topic>` branch; never edit directly on `main`.
- One logical concern per commit. Stage files by name.
- Run local validation before opening a PR (see above).

### License

MIT. See `LICENSE`.
