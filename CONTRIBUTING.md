# Contributing to anaiis-plugins

## Plugin structure

Each plugin lives in a top-level directory with the following layout:

```
<plugin>/
  .claude-plugin/
    plugin.json       # plugin manifest (name, description, version, author)
  skills/
    <skill-name>/
      SKILL.md        # skill definition (router, <=500 tokens)
      references/     # optional: deep reference docs loaded on demand
      lib/            # optional: shell/Python helpers; lib/smoke.sh holds fixture tests
      agents/         # optional: skill-local agent definitions
  agents/             # plugin-level shared agents
  lib/                # optional: plugin-level scripts shared across skills
```

Skills and agents are auto-discovered from `skills/*/SKILL.md` and `agents/*.md`;
`plugin.json` never lists them.

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

1. Create `<plugin>/skills/<skill-name>/SKILL.md` with required frontmatter. No manifest
   edit for the skill itself; skills are auto-discovered.
2. Bump `version` in `<plugin>/.claude-plugin/plugin.json` (see "Versioning and releases").
3. Run `python scripts/lint-skills.py` and fix any reported issues.
4. Run `python scripts/count-skill-tokens.py` and trim if any skill exceeds 500 tokens.
5. Open a PR; the `validate.yml` CI workflow will re-run both checks.

## Versioning and releases

Every merge that changes a plugin's skills, agents, or lib scripts must bump that plugin's
`version` in `plugin.json`. This is how Claude Code resolves updates; per the official
plugin docs, pushing new commits without changing the version string does nothing for
existing users, who keep the cached copy of the old release. (Omitting `version` would make
every commit a release automatically; this repo keeps explicit version numbers for readable
cache paths and changelogs.)

## Token budget

SKILL.md router files are loaded into Claude's context on every applicable session. The
500-token target keeps per-skill overhead low. Use `scripts/count-skill-tokens.py` to
measure before opening a PR.

## After merging a plugin change

Claude Code loads the plugin version pinned in `~/.claude/plugins/installed_plugins.json`,
not whatever is newest in the marketplace clone or cache. After every merge that touches
skills, agents, lib scripts, or `plugin.json`:

1. Pull the marketplace clone that Claude Code maintains locally:
   ```bash
   git -C ~/.claude/plugins/marketplaces/anaiis-plugins pull
   ```

2. Repin to the new version. This is the only step that moves the pin:
   ```
   /plugin                                        (interactive update flow)
   claude plugin update <plugin>@anaiis-plugins   (CLI equivalent)
   ```

3. Apply it in-session:
   ```
   /reload-plugins
   ```

4. Verify with a live invocation: run any skill from the plugin and confirm the
   "Base directory for this skill" line in its invocation context resolves to the new
   version's cache path (e.g., `.../anaiis-review/0.1.9/...`).

**Why each step matters:** `/reload-plugins` alone never repins; it reloads whatever
version is already installed. Cache-directory contents, marketplace git state, and even a
passing `lib/smoke.sh` run against the new cache path do not prove the harness loads that
version; only step 4's live path check does. Skipping the version bump upstream makes the
release invisible entirely (see "Versioning and releases").
