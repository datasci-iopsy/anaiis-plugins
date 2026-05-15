# graphify incremental modes

Set `$PYTHON` first for all sections:

```bash
PYTHON=$(bash ~/.claude/skills/graphify/scripts/graphify-env.sh)
```

---

## --update (incremental re-extraction)

Use when files have been added or modified since the last run. Only re-extracts changed files.

```bash
$PYTHON -c "
import sys, json
from graphify.detect import detect_incremental, save_manifest
from pathlib import Path

result = detect_incremental(Path('INPUT_PATH'))
new_total = result.get('new_total', 0)
print(json.dumps(result, indent=2))
Path('.graphify_incremental.json').write_text(json.dumps(result))
if new_total == 0:
    print('No files changed since last run. Nothing to update.')
    raise SystemExit(0)
print(f'{new_total} new/changed file(s) to re-extract.')
"
```

Check whether all changed files are code files:

```bash
$PYTHON -c "
import json
from pathlib import Path

result = json.loads(open('.graphify_incremental.json').read()) if Path('.graphify_incremental.json').exists() else {}
code_exts = {'.py','.ts','.js','.go','.rs','.java','.cpp','.c','.rb','.swift','.kt','.cs','.scala','.php','.cc','.cxx','.hpp','.h','.kts','.lua','.toc'}
new_files = result.get('new_files', {})
all_changed = [f for files in new_files.values() for f in files]
code_only = all(Path(f).suffix.lower() in code_exts for f in all_changed)
print('code_only:', code_only)
"
```

- If `code_only` is True: print `[graphify update] Code-only changes detected - skipping semantic extraction (no LLM needed)`, run only Step 3A (AST) on the changed files, skip Step 3B entirely, then go to merge and Steps 4-8.
- If `code_only` is False: run the full Steps 3A-3C pipeline as normal.

Before merging, save a backup and merge:

```bash
cp graphify-out/graph.json .graphify_old.json

$PYTHON -c "
import sys, json
from graphify.build import build_from_json
from graphify.export import to_json
from networkx.readwrite import json_graph
import networkx as nx
from pathlib import Path

existing_data = json.loads(Path('graphify-out/graph.json').read_text())
G_existing = json_graph.node_link_graph(existing_data, edges='links')

new_extraction = json.loads(Path('.graphify_extract.json').read_text())
G_new = build_from_json(new_extraction)

G_existing.update(G_new)
print(f'Merged: {G_existing.number_of_nodes()} nodes, {G_existing.number_of_edges()} edges')
"
```

Then run Steps 4-8 on the merged graph.

After Step 4, show the graph diff:

```bash
$PYTHON -c "
import json
from graphify.analyze import graph_diff
from graphify.build import build_from_json
from networkx.readwrite import json_graph
import networkx as nx
from pathlib import Path

old_data = json.loads(Path('.graphify_old.json').read_text()) if Path('.graphify_old.json').exists() else None
new_extract = json.loads(Path('.graphify_extract.json').read_text())
G_new = build_from_json(new_extract)

if old_data:
    G_old = json_graph.node_link_graph(old_data, edges='links')
    diff = graph_diff(G_old, G_new)
    print(diff['summary'])
    if diff['new_nodes']:
        print('New nodes:', ', '.join(n['label'] for n in diff['new_nodes'][:5]))
    if diff['new_edges']:
        print('New edges:', len(diff['new_edges']))
"
rm -f .graphify_old.json
```

---

## --cluster-only

Skip Steps 1-3. Load the existing graph from `graphify-out/graph.json` and re-run clustering:

```bash
$PYTHON -c "
import sys, json
from graphify.cluster import cluster, score_all
from graphify.analyze import god_nodes, surprising_connections
from graphify.report import generate
from graphify.export import to_json
from networkx.readwrite import json_graph
import networkx as nx
from pathlib import Path

data = json.loads(Path('graphify-out/graph.json').read_text())
G = json_graph.node_link_graph(data, edges='links')

detection = {'total_files': 0, 'total_words': 99999, 'needs_graph': True, 'warning': None,
             'files': {'code': [], 'document': [], 'paper': []}}
tokens = {'input': 0, 'output': 0}

communities = cluster(G)
cohesion = score_all(G, communities)
gods = god_nodes(G)
surprises = surprising_connections(G, communities)
labels = {cid: 'Community ' + str(cid) for cid in communities}

report = generate(G, communities, cohesion, labels, gods, surprises, detection, tokens, '.')
Path('graphify-out/GRAPH_REPORT.md').write_text(report)
to_json(G, communities, 'graphify-out/graph.json')

analysis = {
    'communities': {str(k): v for k, v in communities.items()},
    'cohesion': {str(k): v for k, v in cohesion.items()},
    'gods': gods,
    'surprises': surprises,
}
Path('.graphify_analysis.json').write_text(json.dumps(analysis, indent=2))
print(f'Re-clustered: {len(communities)} communities')
"
```

Then run Steps 5-9 as normal.

---

## --watch

Start a background watcher that monitors a folder and auto-updates the graph on file changes.

```bash
$PYTHON -m graphify.watch INPUT_PATH --debounce 3
```

Behavior by file type changed:
- **Code files only:** re-runs AST extraction + rebuild + cluster immediately. No LLM needed.
- **Docs, papers, or images:** writes `graphify-out/needs_update` flag and prints a notification to run `/graphify --update`.

Press Ctrl+C to stop.

---

## Git commit hook

Install a post-commit hook that auto-rebuilds the graph after every commit:

```bash
$PYTHON -m graphify hook install    # install
$PYTHON -m graphify hook uninstall  # remove
$PYTHON -m graphify hook status     # check
```

After every `git commit`, the hook detects which code files changed, re-runs AST extraction, and rebuilds `graph.json` and `GRAPH_REPORT.md`. Doc/image changes are ignored; run `/graphify --update` manually for those.

---

## graphify claude install (CLAUDE.md integration)

Run once per project to make graphify always-on in Claude Code sessions:

```bash
$PYTHON -m graphify claude install
```

This writes a `## graphify` section to the local `CLAUDE.md`. Remove with:

```bash
$PYTHON -m graphify claude uninstall
```

---

## --wiki

```bash
$PYTHON -c "
import json
from graphify.build import build_from_json
from graphify.wiki import to_wiki
from pathlib import Path

extraction = json.loads(Path('.graphify_extract.json').read_text())
analysis   = json.loads(Path('.graphify_analysis.json').read_text())
labels_raw = json.loads(Path('.graphify_labels.json').read_text()) if Path('.graphify_labels.json').exists() else {}

G = build_from_json(extraction)
communities = {int(k): v for k, v in analysis['communities'].items()}
labels = {int(k): v for k, v in labels_raw.items()}

to_wiki(G, communities, 'graphify-out/wiki', community_labels=labels or None)
print('Wiki written to graphify-out/wiki/')
"
```
