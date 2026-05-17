---
name: anaiis-webverify
description: Build and verify web pages, dashboards, and data visualizations in a real browser via a CLI-driven loop. Auto-triggers when the user asks to build, render, or verify a web page, Plotly dashboard, Quarto output, static HTML prototype, or any browser-rendered artifact.
user-invocable: true
trigger: hybrid
version: 0.1.0
---

# Web Build and Verify

A five-phase, terminal-focused workflow for rapidly prototyping and verifying browser-rendered output. Uses `@playwright/test` via `npx` for assertions; never uses the Playwright MCP plugin.

## When to use this skill

- Building static HTML pages or prototypes
- Rendering Plotly (Python) figures to self-contained HTML
- Rendering ggplot2 charts via `plotly::ggplotly()` or `htmlwidgets`
- Verifying Quarto or R Markdown HTML output in a real browser
- Any task requiring "generate, serve, assert, screenshot" in a loop

## When NOT to use this skill

- Data analysis, SQL, or file queries (use anaiis-duckdb)
- Literature review or synthesis (use anaiis-litreview)
- Git, PR, or commit operations (use anaiis-gitpr / anaiis-gitrebase)
- Tasks that produce no browser-rendered artifact

## Setup requirements

These are one-time per machine; check before scaffolding:

```bash
npx playwright --version 2>/dev/null || echo "not installed"
npx playwright install chromium 2>/dev/null | tail -1
```

Templates live at `~/anaiis-dotfiles/templates/`:
- `playwright-static/` for static HTML
- `playwright-plotly/` for Plotly Python figures
- `playwright-ggplot2/` for ggplot2/htmlwidgets output

The `web-verify` helper script at `~/anaiis-dotfiles/bin/web-verify` wraps the serve-test-teardown cycle.

## Phase 1: Scope and scaffold

1. State the deliverable in one sentence before touching any file.
2. Confirm which template applies (static, plotly, ggplot2).
3. If the working directory lacks `playwright.config.ts`, copy from the appropriate template:
   ```bash
   cp -r ~/anaiis-dotfiles/templates/playwright-static/. .
   npm install --save-dev @playwright/test
   ```
4. **Gate**: all three must pass before proceeding:
   ```bash
   npx playwright --version
   ls tests/smoke.spec.ts
   npx playwright test --list 2>&1 | grep -qE "smoke" && echo "runner ok"
   ```

## Phase 2: Generate

Build the artifact. Tool choice by stack:

| Stack | Command |
|---|---|
| Pure HTML/CSS | Claude writes directly to `index.html` |
| Plotly Python | `uv run python render.py` (copies from template if absent) |
| ggplot2 / htmlwidgets | `Rscript render.R` (copies from template if absent) |
| Quarto | `quarto render index.qmd --to html` |

**Gate**: all three must pass:
```bash
test -f index.html
test $(wc -c < index.html) -gt 1000
echo "size ok"
```

If the render script produces an error, fix the error before advancing. Do not advance on a missing or empty output file.

## Phase 3: Serve and verify

Use the `web-verify` script:

```bash
web-verify run
```

This script:
1. Finds a free port (default 8080, increments if taken).
2. Starts `python3 -m http.server <port>` in the background, waits for bind.
3. Runs `npx playwright test` with reporters configured in `playwright.config.ts` (list to console, json to `test-results/last-run.json`).
4. Tears down the server (kills the background PID).
5. Exits with the playwright exit code.

The smoke spec asserts:
- HTTP 200 on `/`
- `document.title` is non-empty
- No `console.error` events
- At least one expected DOM node present (configurable per-project via `TEST_SELECTOR` env var)
- For Plotly: `.plotly` div exists and is non-empty

**Gate**: `web-verify run` exits 0.

On failure: read only the failing assertion line from `test-results/last-run.json`. Do not read the full trace unless the assertion message is ambiguous. Go to Phase 4.

## Phase 4: Iterate

- Read the specific failure from `test-results/last-run.json`.
- If the failure requires visual inspection, use `Read` on the failure screenshot at `test-results/*/test-failed-*.png`. Do not read screenshots preemptively.
- Fix the source. Re-run Phase 3.
- **Hard cap: 3 iterations.** After 3 consecutive failures, stop. Report the blocker with the exact failing assertion, the last screenshot path, and a suggested diagnosis. Do not continue iterating silently.

## Phase 5: Acceptance

1. Run final clean pass: `web-verify run`
2. Save screenshot to deterministic path: `artifacts/screenshot-<slug>.png`
3. Report:
   - Files written (list)
   - Command to re-verify: `web-verify run`
   - Screenshot path
   - Each acceptance criterion from Phase 1 mapped to the passing assertion that covers it

**Gate**: every criterion from Phase 1 has a corresponding passing assertion. If any criterion was not tested, state it explicitly rather than claiming full acceptance.

## Token discipline

- Never read `node_modules/` contents.
- Never read `playwright-report/` HTML files (they are for humans, not Claude).
- Read `test-results/last-run.json` only when a test fails and the terminal output is insufficient. Failures include the locator, expected value, and screenshot path in terminal output; that is usually enough.
- Read screenshots only when the assertion message is insufficient to diagnose.
- Do not re-run tests to confirm a known pass; trust the exit code.

## Extending to other stacks

**Shiny**: not yet supported. Background R process management is a follow-up. Flag to the user and stop.

**Streamlit**: not yet supported. Background `uv run streamlit` management is a follow-up. Flag to the user and stop.

**Visual regression diffs**: `expect(page).toHaveScreenshot()` is available in `@playwright/test` but requires baseline management. Use only if the user explicitly asks for it.
