# Contributing to anaiis-plugins

## Plugin structure

Each plugin lives in a top-level directory with the following layout:

```
<plugin>/
  .claude-plugin/
    plugin.json       # plugin manifest (name, version, skills list)
  skills/
    <skill-name>/
      SKILL.md        # skill definition (router, <=500 tokens)
      references/     # optional: deep reference docs loaded on demand
      scripts/        # optional: helper scripts referenced from SKILL.md
      assets/         # optional: templates, examples
```

## Trigger conventions

Three trigger modes are used across skills:

| Mode | When | How invoked |
|------|------|-------------|
| `auto` | Description clearly matches a narrow, unambiguous task | Fires when Claude infers the skill applies |
| `manual` | Broad or easily-confused skills; destructive or non-reversible ops | User types `/<skill-name>` explicitly |
| `hybrid` | Core path is auto; secondary paths require explicit invocation | Both |

Default to `manual` when uncertain. Auto-trigger scope creep produces surprising behavior.

## SKILL.md requirements

Every `SKILL.md` must have these frontmatter fields:

```yaml
---
name: <skill-name>
description: <one sentence; used for auto-trigger matching and /help display>
user-invocable: true|false
trigger: auto|manual|hybrid
version: 0.1.0
---
```

Keep the router content under 500 tokens. Deep content belongs in `references/` and is
loaded only when the relevant phase runs.

## Adding a skill

1. Create `<plugin>/skills/<skill-name>/SKILL.md` with required frontmatter.
2. Add the skill entry to `<plugin>/.claude-plugin/plugin.json` under `"skills"`.
3. Run `python scripts/lint-skills.py` and fix any reported issues.
4. Run `python scripts/count-skill-tokens.py` and trim if any skill exceeds 500 tokens.
5. Open a PR; the `validate.yml` CI workflow will re-run both checks.

## Token budget

SKILL.md router files are loaded into Claude's context on every applicable session. The
500-token target keeps per-skill overhead low. Use `scripts/count-skill-tokens.py` to
measure before opening a PR.
