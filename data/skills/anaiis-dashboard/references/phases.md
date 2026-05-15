# anaiis-dashboard: Phase Detail

## Phase 1: Manifest and acceptance criteria

Before writing any code, Claude asks:
1. Who is the audience (executive, ops team, technical reviewer)?
2. What is the narrative arc (one or two sentences the viewer should finish with)?
3. What specific questions must each chart answer?

From those answers, write `dashboard.config.json`. Validate immediately:

```bash
uv run python ~/.dotfiles/templates/dashboard/validate_manifest.py dashboard.config.json
```

**Gate**: exits 0 with "OK: manifest valid". If it fails, fix the manifest before continuing.

---

## Phase 2: Data acquisition

For each chart in the manifest, run the appropriate command based on `data_source.kind`:

```bash
# kind: duckdb
mkdir -p data
duckdb -json -c "<query>" > data/<id>.json

# kind: bq
bq query --format=json --use_legacy_sql=false "<query>" > data/<id>.json

# kind: file
cp <source_path> data/<id>.<ext>
```

**Gate**: every chart has a non-empty file under `data/`. Check with:
```bash
for id in $(jq -r '.charts[].id' dashboard.config.json); do
    test -s data/${id}.json || test -s data/${id}.parquet || echo "MISSING: data/${id}"
done
```

---

## Phase 3: Chart rendering

For each chart, write a `scripts/build_<id>.py` (or `.R`) if it doesn't exist, then run it:

```bash
mkdir -p scripts artifacts/charts
uv run python scripts/build_<id>.py   # Plotly: reads data/<id>.json, writes artifacts/charts/<id>.fig.json
Rscript scripts/build_<id>.R          # ggplot2: same contract
```

Each `fig_builder` script must:
- Read from `data/<id>.json` (or parquet)
- Write `fig.to_json()` output to `artifacts/charts/<id>.fig.json`
- Print a one-line confirmation to stdout

**Gate**: every fig.json exists, is non-empty, and parses as JSON with `data` and `layout` keys:
```bash
for id in $(jq -r '.charts[].id' dashboard.config.json); do
    python3 -c "
import json, sys
d = json.load(open('artifacts/charts/${id}.fig.json'))
assert 'data' in d and 'layout' in d, 'missing keys'
print('OK: ${id}')
" || echo "FAIL: ${id}"
done
```

---

## Phase 4: Shell generation (frontend-design)

Pass the following to `frontend-design`. If the plugin is not installed, tell the user to run `/plugin install frontend-design@claude-plugins-official` and pause.

Prompt template (fill in from manifest):
```
Build a single-page HTML dashboard titled "<manifest.title>".
Audience: <manifest.audience>.
Narrative: <manifest.narrative_arc>.

The page must include one section per chart, in this exact order:
<for each chart>
  - Section heading: "<chart.title>"
  - One-sentence description: "<chart.description>"
  - A div with:
      id="chart-<chart.id>"
      class="chart-mount"
      data-fig="artifacts/charts/<chart.id>.fig.json"
      style="width:100%;height:480px"

The div must be empty (no children). Plotly will hydrate it at runtime via a bootstrap script.
Include a CDN script tag for Plotly: https://cdn.plot.ly/plotly-2.32.0.min.js
Do NOT include any other charting library.
Output single-file HTML with all CSS inlined in <style> tags.
```

**Gate**: validate mount coverage immediately after `frontend-design` writes `index.html`:
```bash
uv run python ~/.dotfiles/templates/dashboard/validate_manifest.py dashboard.config.json --check-mounts index.html
```

---

## Phase 5: Wire and inline

Convert to a single self-contained file:

```bash
uv run python ~/.dotfiles/templates/dashboard/inline_charts.py \
    --manifest dashboard.config.json \
    --html index.html \
    --out index.html
```

**Gate**: check that no external `data-fig` references remain and each chart has an inline script block:
```bash
grep -c 'data-fig=' index.html && echo "FAIL: external fig refs remain" || echo "OK: no external refs"
for id in $(jq -r '.charts[].id' dashboard.config.json); do
    grep -q "id=\"chart-${id}\"" index.html && echo "OK: chart-${id} inlined" || echo "FAIL: chart-${id} missing"
done
```

---

## Phase 6: Verification

Copy the dashboard spec into place (if not already done) and run:

```bash
MANIFEST_PATH=dashboard.config.json web-verify run
```

The `dashboard.spec.ts` asserts per chart:
- Mount div is visible
- `data-plotly-rendered="true"` is set within 10 seconds
- No `data-plotly-error` attribute
- At least one non-empty SVG inside the mount

Hard cap: 3 iteration cycles on failure. After 3, stop and report the blocker.

**Gate**: `web-verify run` exits 0.

---

## Phase 7: Acceptance

```bash
web-verify screenshot
```

Checklist (Claude states each item explicitly):

**Chart coverage**: for each chart in the manifest, state which assertion in `dashboard.spec.ts` covered it.

**Narrative-data alignment**: for each chart, compare the `description` field to what the rendered data actually shows. State "ALIGNED" or flag the mismatch. If misaligned, ask: revise the description or revise the analysis?

**Stakeholder readiness**:
- Is the title jargon-free?
- Are cohort names, date ranges, and metric names spelled out (not abbreviated)?
- Would a non-technical reader understand the story from title + descriptions alone?

**Gate**: all items are either "OK" or "SKIPPED: <reason>". No item may be silently passed over.

Deliverable summary at the end of Phase 7:
```
Dashboard: index.html (<size> KB)
Screenshot: artifacts/screenshot-dashboard.png
Charts: <n> verified
Cleanup: rm -rf <project_dir>   (if this was a demo/tmp run)
```
