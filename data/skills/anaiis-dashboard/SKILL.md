---
name: anaiis-dashboard
description: Build stakeholder-facing dashboards and validation report pages combining Plotly or ggplot2 charts with a designed page shell. Auto-triggers when the user asks to present, share, or build a dashboard, report page, or visualization for teammates, clients, or stakeholders.
user-invocable: true
trigger: hybrid
version: 0.1.0
---

# Stakeholder Dashboard Orchestrator

Seven-phase workflow that coordinates data acquisition, chart rendering, shell generation, wiring, and browser verification into a single deliverable: a self-contained HTML dashboard ready to share with non-technical stakeholders.

Delegates to:
- **frontend-design** (must be installed: `/plugin install frontend-design@claude-plugins-official`) for page aesthetics
- **anaiis-webverify** for browser assertions
- `render.py` / `render.R` templates for Plotly and ggplot2 figures

The manifest (`dashboard.config.json`) is the contract between all three. Never advance a phase without a valid manifest.

## When to use this skill

- Building a presentation-ready page for internal or external stakeholders
- Turning a markdown analysis or validation report into a visual dashboard
- Producing a chart-rich HTML page from BQ queries, dbt models, or local parquet files

## When NOT to use this skill

- Exploratory analysis for your own use (stay in markdown / DuckDB)
- Verifying a single chart in isolation (use anaiis-webverify directly)
- Literature review, copyediting, or data query tasks (use the relevant specialist skill)

## Prerequisites (check once per machine)

```bash
npx playwright --version
which web-verify
ls ~/anaiis-dotfiles/templates/dashboard/validate_manifest.py
# frontend-design must be installed: /plugin install frontend-design@claude-plugins-official
```

## Project layout expected

```
dashboard.config.json       <- manifest (Phase 1 writes this)
data/                       <- raw query results (Phase 2)
scripts/                    <- fig_builder scripts (Phase 3, one per chart)
artifacts/charts/           <- fig.json outputs (Phase 3)
index.html                  <- shell + wired output (Phase 4-5)
artifacts/screenshot-dashboard.png
test-results/last-run.json
```

## Phase overview

Load `references/phases.md` when a phase begins.

| Phase | Name | Action |
|---|---|---|
| 1 | Manifest and acceptance criteria | Ask audience/narrative/questions, write and validate `dashboard.config.json` |
| 2 | Data acquisition | Run queries per `data_source.kind`; gate on non-empty data files |
| 3 | Chart rendering | Write and run `fig_builder` scripts; gate on valid `fig.json` output |
| 4 | Shell generation | Invoke frontend-design with manifest context |
| 5 | Wire and inline | Run `inline_charts.py`; confirm no external refs remain |
| 6 | Verification | Run `web-verify run`; hard cap 3 iterations |
| 7 | Acceptance | Screenshot, narrative-data alignment check, stakeholder readiness |

## Data provenance rule

Every chart in the manifest has a `data_source` pointing to a real query or file. If a chart is requested without one, stop and ask where the data lives. Never fabricate chart data.
