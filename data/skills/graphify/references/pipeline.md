# graphify pipeline (Steps 1-9)

Full build pipeline. Follow steps in order. Do not skip steps.

**In every bash block below, `$PYTHON` refers to the variable set in Step 1. Do not use `python3` or `python` directly.**

---

## Step 1 - Verify graphify environment

```bash
bash ~/.claude/skills/graphify/scripts/preflight.sh
```

If this exits non-zero, stop and show the user the remediation message printed to stderr. Do not proceed.

If it exits 0, set the interpreter variable for all subsequent steps:

```bash
PYTHON=$(bash ~/.claude/skills/graphify/scripts/graphify-env.sh)
```

Use `$PYTHON` in every subsequent bash block. Never write `$(cat .graphify_python)`.

---

## Step 2 - Detect files

Replace `INPUT_PATH` with the actual path the user provided (or `.` if none given).

```bash
$PYTHON -c "
import json
from graphify.detect import detect
from pathlib import Path
result = detect(Path('INPUT_PATH'))
print(json.dumps(result))
" > .graphify_detect.json
```

Do NOT cat or print the JSON. Read it silently and present a clean summary:

```
Corpus: X files · ~Y words
  code:     N files (.py .ts .go ...)
  docs:     N files (.md .txt ...)
  papers:   N files (.pdf ...)
  images:   N files
```

Then apply the corpus-size guardrails from SKILL.md before proceeding to Step 3.

---

## Step 3 - Extract entities and relationships

**Before starting:** note whether `--mode deep` was given. Pass `DEEP_MODE=true` to every subagent if so. Track this from the original invocation.

Run Part A (AST) and Part B (semantic) in parallel. Dispatch all semantic subagents AND start AST extraction in the same message.

### Part A - Structural extraction for code files

```bash
$PYTHON -c "
import sys, json
from graphify.extract import collect_files, extract
from pathlib import Path
import json

code_files = []
detect = json.loads(Path('.graphify_detect.json').read_text())
for f in detect.get('files', {}).get('code', []):
    code_files.extend(collect_files(Path(f)) if Path(f).is_dir() else [Path(f)])

if code_files:
    result = extract(code_files)
    Path('.graphify_ast.json').write_text(json.dumps(result, indent=2))
    print(f'AST: {len(result[\"nodes\"])} nodes, {len(result[\"edges\"])} edges')
else:
    Path('.graphify_ast.json').write_text(json.dumps({'nodes':[],'edges':[],'input_tokens':0,'output_tokens':0}))
    print('No code files - skipping AST extraction')
"
```

### Part B - Semantic extraction (parallel subagents)

**Fast path:** If detection found zero docs, papers, and images (code-only corpus), skip Part B entirely. Go to Part C.

**MANDATORY: Use the Agent tool here. Reading files one-by-one is forbidden; it is 5-10x slower.**

Before dispatching, calculate and show a cost estimate, then wait for user confirmation:
- `ceil(uncached_non_code_files / 22)` agents needed
- Estimate time: ~45s per agent batch
- Estimate tokens: ~3k-5k per uncached file
- Print: "Semantic extraction: ~N files -> X agents, estimated ~Ys and ~Xk-Yk tokens. Proceed? (y/n)"
- Wait for answer. If no, stop here.

**Step B0 - Check extraction cache first**

```bash
$PYTHON -c "
import json
from graphify.cache import check_semantic_cache
from pathlib import Path

detect = json.loads(Path('.graphify_detect.json').read_text())
all_files = [f for files in detect['files'].values() for f in files]

cached_nodes, cached_edges, cached_hyperedges, uncached = check_semantic_cache(all_files)

if cached_nodes or cached_edges or cached_hyperedges:
    Path('.graphify_cached.json').write_text(json.dumps({'nodes': cached_nodes, 'edges': cached_edges, 'hyperedges': cached_hyperedges}))
Path('.graphify_uncached.txt').write_text('\n'.join(uncached))
print(f'Cache: {len(all_files)-len(uncached)} files hit, {len(uncached)} files need extraction')
"
```

Only dispatch subagents for files in `.graphify_uncached.txt`. If all are cached, skip to Part C.

**Step B1 - Split into chunks**

Load files from `.graphify_uncached.txt`. Split into chunks of 20-25 files. Each image gets its own chunk.

**Step B2 - Dispatch ALL subagents in a single message**

One Agent tool call per chunk, all in the same response. Each subagent receives this prompt (substitute FILE_LIST, CHUNK_NUM, TOTAL_CHUNKS, DEEP_MODE):

```
You are a graphify extraction subagent. Read the files listed and extract a knowledge graph fragment.
Output ONLY valid JSON matching the schema below - no explanation, no markdown fences, no preamble.

Files (chunk CHUNK_NUM of TOTAL_CHUNKS):
FILE_LIST

Rules:
- EXTRACTED: relationship explicit in source (import, call, citation, "see §3.2")
- INFERRED: reasonable inference (shared data structure, implied dependency)
- AMBIGUOUS: uncertain - flag for review, do not omit

Code files: focus on semantic edges AST cannot find (call relationships, shared data, arch patterns).
  Do not re-extract imports - AST already has those.
Doc/paper files: extract named concepts, entities, citations. Also extract rationale, sections that
  explain WHY a decision was made, trade-offs chosen, or design intent. These become nodes with
  rationale_for edges pointing to the concept they explain.
Image files: use vision to understand what the image IS - do not just OCR.
  UI screenshot: layout patterns, design decisions, key elements, purpose.
  Chart: metric, trend/insight, data source.
  Tweet/post: claim as node, author, concepts mentioned.
  Diagram: components and connections.
  Research figure: what it demonstrates, method, result.
  Handwritten/whiteboard: ideas and arrows, mark uncertain readings AMBIGUOUS.

DEEP_MODE (if --mode deep was given): be aggressive with INFERRED edges - indirect deps,
  shared assumptions, latent couplings. Mark uncertain ones AMBIGUOUS instead of omitting.

Semantic similarity: if two concepts solve the same problem or represent the same idea without any
  structural link, add a semantically_similar_to edge marked INFERRED with a confidence_score (0.6-0.95).
  Only add these when the similarity is genuinely non-obvious and cross-cutting.

Hyperedges: if 3+ nodes clearly participate together in a shared concept, flow, or pattern not
  captured by pairwise edges, add a hyperedge to a top-level hyperedges array. Maximum 3 per chunk.

If a file has YAML frontmatter (--- ... ---), copy source_url, captured_at, author, contributor
  onto every node from that file.

confidence_score is REQUIRED on every edge:
- EXTRACTED: 1.0 always
- INFERRED: 0.6-0.9 (direct evidence: 0.8-0.9, reasonable inference: 0.6-0.7, weak: 0.4-0.5)
- AMBIGUOUS: 0.1-0.3

Output exactly this JSON (no other text):
{"nodes":[{"id":"filestem_entityname","label":"Human Readable Name","file_type":"code|document|paper|image","source_file":"relative/path","source_location":null,"source_url":null,"captured_at":null,"author":null,"contributor":null}],"edges":[{"source":"node_id","target":"node_id","relation":"calls|implements|references|cites|conceptually_related_to|shares_data_with|semantically_similar_to|rationale_for","confidence":"EXTRACTED|INFERRED|AMBIGUOUS","confidence_score":1.0,"source_file":"relative/path","source_location":null,"weight":1.0}],"hyperedges":[{"id":"snake_case_id","label":"Human Readable Label","nodes":["node_id1","node_id2","node_id3"],"relation":"participate_in|implement|form","confidence":"EXTRACTED|INFERRED","confidence_score":0.75,"source_file":"relative/path"}],"input_tokens":0,"output_tokens":0}
```

**Step B3 - Collect, cache, and merge**

Wait for all subagents. For each result:
- Valid JSON with `nodes` and `edges`: include it, save to cache.
- Failed or invalid JSON: print a warning, skip that chunk. Do not abort.
- If more than half the chunks failed: stop and tell the user.

Save new results to cache:

```bash
$PYTHON -c "
import json
from graphify.cache import save_semantic_cache
from pathlib import Path

new = json.loads(Path('.graphify_semantic_new.json').read_text()) if Path('.graphify_semantic_new.json').exists() else {'nodes':[],'edges':[],'hyperedges':[]}
saved = save_semantic_cache(new.get('nodes', []), new.get('edges', []), new.get('hyperedges', []))
print(f'Cached {saved} files')
"
```

Merge cached + new results into `.graphify_semantic.json`:

```bash
$PYTHON -c "
import json
from pathlib import Path

cached = json.loads(Path('.graphify_cached.json').read_text()) if Path('.graphify_cached.json').exists() else {'nodes':[],'edges':[],'hyperedges':[]}
new = json.loads(Path('.graphify_semantic_new.json').read_text()) if Path('.graphify_semantic_new.json').exists() else {'nodes':[],'edges':[],'hyperedges':[]}

all_nodes = cached['nodes'] + new.get('nodes', [])
all_edges = cached['edges'] + new.get('edges', [])
all_hyperedges = cached.get('hyperedges', []) + new.get('hyperedges', [])
seen = set()
deduped = []
for n in all_nodes:
    if n['id'] not in seen:
        seen.add(n['id'])
        deduped.append(n)

merged = {
    'nodes': deduped,
    'edges': all_edges,
    'hyperedges': all_hyperedges,
    'input_tokens': new.get('input_tokens', 0),
    'output_tokens': new.get('output_tokens', 0),
}
Path('.graphify_semantic.json').write_text(json.dumps(merged, indent=2))
print(f'Extraction complete - {len(deduped)} nodes, {len(all_edges)} edges ({len(cached[\"nodes\"])} from cache, {len(new.get(\"nodes\",[]))} new)')
"
```

Clean up temp files: `rm -f .graphify_cached.json .graphify_uncached.txt .graphify_semantic_new.json`

### Part C - Merge AST + semantic into final extraction

```bash
$PYTHON -c "
import sys, json
from pathlib import Path

ast = json.loads(Path('.graphify_ast.json').read_text())
sem = json.loads(Path('.graphify_semantic.json').read_text())

seen = {n['id'] for n in ast['nodes']}
merged_nodes = list(ast['nodes'])
for n in sem['nodes']:
    if n['id'] not in seen:
        merged_nodes.append(n)
        seen.add(n['id'])

merged_edges = ast['edges'] + sem['edges']
merged_hyperedges = sem.get('hyperedges', [])
merged = {
    'nodes': merged_nodes,
    'edges': merged_edges,
    'hyperedges': merged_hyperedges,
    'input_tokens': sem.get('input_tokens', 0),
    'output_tokens': sem.get('output_tokens', 0),
}
Path('.graphify_extract.json').write_text(json.dumps(merged, indent=2))
total = len(merged_nodes)
edges = len(merged_edges)
print(f'Merged: {total} nodes, {edges} edges ({len(ast[\"nodes\"])} AST + {len(sem[\"nodes\"])} semantic)')
"
```

---

## Step 4 - Build graph, cluster, analyze, generate outputs

Replace `INPUT_PATH` with the actual path.

```bash
mkdir -p graphify-out
$PYTHON -c "
import sys, json
from graphify.build import build_from_json
from graphify.cluster import cluster, score_all
from graphify.analyze import god_nodes, surprising_connections, suggest_questions
from graphify.report import generate
from graphify.export import to_json
from pathlib import Path

extraction = json.loads(Path('.graphify_extract.json').read_text())
detection  = json.loads(Path('.graphify_detect.json').read_text())

G = build_from_json(extraction)
communities = cluster(G)
cohesion = score_all(G, communities)
tokens = {'input': extraction.get('input_tokens', 0), 'output': extraction.get('output_tokens', 0)}
gods = god_nodes(G)
surprises = surprising_connections(G, communities)
labels = {cid: 'Community ' + str(cid) for cid in communities}
questions = suggest_questions(G, communities, labels)

report = generate(G, communities, cohesion, labels, gods, surprises, detection, tokens, 'INPUT_PATH', suggested_questions=questions)
Path('graphify-out/GRAPH_REPORT.md').write_text(report)
to_json(G, communities, 'graphify-out/graph.json')

analysis = {
    'communities': {str(k): v for k, v in communities.items()},
    'cohesion': {str(k): v for k, v in cohesion.items()},
    'gods': gods,
    'surprises': surprises,
    'questions': questions,
}
Path('.graphify_analysis.json').write_text(json.dumps(analysis, indent=2))
if G.number_of_nodes() == 0:
    print('ERROR: Graph is empty - extraction produced no nodes.')
    raise SystemExit(1)
print(f'Graph: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges, {len(communities)} communities')
"
```

If this prints `ERROR: Graph is empty`, stop and tell the user. Do not proceed to labeling or visualization.

---

## Step 5 - Label communities

Read `.graphify_analysis.json`. For each community key, write a 2-5 word plain-language name (e.g. "Attention Mechanism", "Training Pipeline", "Data Loading").

Then regenerate the report and save the labels:

```bash
$PYTHON -c "
import sys, json
from graphify.build import build_from_json
from graphify.cluster import score_all
from graphify.analyze import god_nodes, surprising_connections, suggest_questions
from graphify.report import generate
from pathlib import Path

extraction = json.loads(Path('.graphify_extract.json').read_text())
detection  = json.loads(Path('.graphify_detect.json').read_text())
analysis   = json.loads(Path('.graphify_analysis.json').read_text())

G = build_from_json(extraction)
communities = {int(k): v for k, v in analysis['communities'].items()}
cohesion = {int(k): v for k, v in analysis['cohesion'].items()}
tokens = {'input': extraction.get('input_tokens', 0), 'output': extraction.get('output_tokens', 0)}

# Replace with the actual labels dict constructed above
labels = LABELS_DICT

questions = suggest_questions(G, communities, labels)
report = generate(G, communities, cohesion, labels, analysis['gods'], analysis['surprises'], detection, tokens, 'INPUT_PATH', suggested_questions=questions)
Path('graphify-out/GRAPH_REPORT.md').write_text(report)
Path('.graphify_labels.json').write_text(json.dumps({str(k): v for k, v in labels.items()}))
print('Report updated with community labels')
"
```

Replace `LABELS_DICT` with the actual dict (e.g. `{0: "Attention Mechanism", 1: "Training Pipeline"}`).
Replace `INPUT_PATH` with the actual path.

---

## Step 6 - Generate Obsidian vault (opt-in) + HTML

**Generate HTML always** (unless `--no-viz`). **Obsidian vault only if `--obsidian` was explicitly given.**

If `--obsidian` was given, use `--obsidian-dir <path>` if provided, otherwise default to `graphify-out/obsidian`:

```bash
$PYTHON -c "
import sys, json
from graphify.build import build_from_json
from graphify.export import to_obsidian, to_canvas
from pathlib import Path

extraction = json.loads(Path('.graphify_extract.json').read_text())
analysis   = json.loads(Path('.graphify_analysis.json').read_text())
labels_raw = json.loads(Path('.graphify_labels.json').read_text()) if Path('.graphify_labels.json').exists() else {}

G = build_from_json(extraction)
communities = {int(k): v for k, v in analysis['communities'].items()}
cohesion = {int(k): v for k, v in analysis['cohesion'].items()}
labels = {int(k): v for k, v in labels_raw.items()}

obsidian_dir = 'OBSIDIAN_DIR'

n = to_obsidian(G, communities, obsidian_dir, community_labels=labels or None, cohesion=cohesion)
print(f'Obsidian vault: {n} notes in {obsidian_dir}/')

to_canvas(G, communities, f'{obsidian_dir}/graph.canvas', community_labels=labels or None)
print(f'Canvas: {obsidian_dir}/graph.canvas')
"
```

Generate HTML (always, unless `--no-viz`):

```bash
$PYTHON -c "
import sys, json
from graphify.build import build_from_json
from graphify.export import to_html
from pathlib import Path

extraction = json.loads(Path('.graphify_extract.json').read_text())
analysis   = json.loads(Path('.graphify_analysis.json').read_text())
labels_raw = json.loads(Path('.graphify_labels.json').read_text()) if Path('.graphify_labels.json').exists() else {}

G = build_from_json(extraction)
communities = {int(k): v for k, v in analysis['communities'].items()}
labels = {int(k): v for k, v in labels_raw.items()}

if G.number_of_nodes() > 5000:
    print(f'Graph has {G.number_of_nodes()} nodes - too large for HTML viz. Use Obsidian vault instead.')
else:
    to_html(G, communities, 'graphify-out/graph.html', community_labels=labels or None)
    print('graph.html written')
"
```

---

## Step 7 - Optional exports

**`--neo4j`** (Cypher file):

```bash
$PYTHON -c "
import sys, json
from graphify.build import build_from_json
from graphify.export import to_cypher
from pathlib import Path

G = build_from_json(json.loads(Path('.graphify_extract.json').read_text()))
to_cypher(G, 'graphify-out/cypher.txt')
print('cypher.txt written - import with: cypher-shell < graphify-out/cypher.txt')
"
```

**`--neo4j-push <uri>`** (push to running Neo4j; ask user for credentials if not provided):

```bash
$PYTHON -c "
import sys, json
from graphify.build import build_from_json
from graphify.cluster import cluster
from graphify.export import push_to_neo4j
from pathlib import Path

extraction = json.loads(Path('.graphify_extract.json').read_text())
analysis   = json.loads(Path('.graphify_analysis.json').read_text())
G = build_from_json(extraction)
communities = {int(k): v for k, v in analysis['communities'].items()}

result = push_to_neo4j(G, uri='NEO4J_URI', user='NEO4J_USER', password='NEO4J_PASSWORD', communities=communities)
print(f'Pushed: {result[\"nodes\"]} nodes, {result[\"edges\"]} edges')
"
```

**`--svg`**:

```bash
$PYTHON -c "
import sys, json
from graphify.build import build_from_json
from graphify.export import to_svg
from pathlib import Path

extraction = json.loads(Path('.graphify_extract.json').read_text())
analysis   = json.loads(Path('.graphify_analysis.json').read_text())
labels_raw = json.loads(Path('.graphify_labels.json').read_text()) if Path('.graphify_labels.json').exists() else {}

G = build_from_json(extraction)
communities = {int(k): v for k, v in analysis['communities'].items()}
labels = {int(k): v for k, v in labels_raw.items()}

to_svg(G, communities, 'graphify-out/graph.svg', community_labels=labels or None)
print('graph.svg written')
"
```

**`--graphml`**:

```bash
$PYTHON -c "
import json
from graphify.build import build_from_json
from graphify.export import to_graphml
from pathlib import Path

extraction = json.loads(Path('.graphify_extract.json').read_text())
analysis   = json.loads(Path('.graphify_analysis.json').read_text())

G = build_from_json(extraction)
communities = {int(k): v for k, v in analysis['communities'].items()}

to_graphml(G, communities, 'graphify-out/graph.graphml')
print('graph.graphml written')
"
```

**`--mcp`**:

```bash
$PYTHON -m graphify.serve graphify-out/graph.json
```

This starts a stdio MCP server. To configure in Claude Desktop (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "graphify": {
      "command": "/absolute/path/to/vendor/graphify-venv/bin/python",
      "args": ["-m", "graphify.serve", "/absolute/path/to/graphify-out/graph.json"]
    }
  }
}
```

---

## Step 8 - Token reduction benchmark

Only if `total_words > 5,000` from `.graphify_detect.json`:

```bash
$PYTHON -c "
import json
from graphify.benchmark import run_benchmark, print_benchmark
from pathlib import Path

detection = json.loads(Path('.graphify_detect.json').read_text())
result = run_benchmark('graphify-out/graph.json', corpus_words=detection['total_words'])
print_benchmark(result)
"
```

Print the output directly in chat. Skip silently if `total_words <= 5,000`.

---

## Step 9 - Save manifest, update cost tracker, clean up, report

```bash
$PYTHON -c "
import json
from pathlib import Path
from datetime import datetime, timezone
from graphify.detect import save_manifest

detect = json.loads(Path('.graphify_detect.json').read_text())
save_manifest(detect['files'])

extract = json.loads(Path('.graphify_extract.json').read_text())
input_tok = extract.get('input_tokens', 0)
output_tok = extract.get('output_tokens', 0)

cost_path = Path('graphify-out/cost.json')
if cost_path.exists():
    cost = json.loads(cost_path.read_text())
else:
    cost = {'runs': [], 'total_input_tokens': 0, 'total_output_tokens': 0}

cost['runs'].append({
    'date': datetime.now(timezone.utc).isoformat(),
    'input_tokens': input_tok,
    'output_tokens': output_tok,
    'files': detect.get('total_files', 0),
})
cost['total_input_tokens'] += input_tok
cost['total_output_tokens'] += output_tok
cost_path.write_text(json.dumps(cost, indent=2))

print(f'This run: {input_tok:,} input tokens, {output_tok:,} output tokens')
print(f'All time: {cost[\"total_input_tokens\"]:,} input, {cost[\"total_output_tokens\"]:,} output ({len(cost[\"runs\"])} runs)')
"
rm -f .graphify_detect.json .graphify_extract.json .graphify_ast.json .graphify_semantic.json .graphify_analysis.json .graphify_labels.json
rm -f graphify-out/.needs_update 2>/dev/null || true
```

Tell the user (omit obsidian line unless `--obsidian` was given):

```
Graph complete. Outputs in PATH_TO_DIR/graphify-out/

  graph.html          - interactive graph, open in browser
  GRAPH_REPORT.md     - audit report
  graph.json          - raw graph data
  obsidian/           - Obsidian vault (only if --obsidian was given)
```

Paste these three sections from GRAPH_REPORT.md directly into chat:
- God Nodes
- Surprising Connections
- Suggested Questions

Do NOT paste the full report. Then pick the single most interesting suggested question and offer to trace it.
