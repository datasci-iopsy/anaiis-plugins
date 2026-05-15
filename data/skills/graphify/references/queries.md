# graphify queries: query / path / explain

All three subcommands require an existing graph. Set `$PYTHON` first:

```bash
PYTHON=$(bash ~/.claude/skills/graphify/scripts/graphify-env.sh)
```

Check the graph exists before any query:

```bash
$PYTHON -c "
from pathlib import Path
if not Path('graphify-out/graph.json').exists():
    print('ERROR: No graph found. Run /graphify <path> first to build the graph.')
    raise SystemExit(1)
"
```

If it fails, stop and tell the user to run `/graphify <path>` first.

---

## /graphify query

Two traversal modes:

| Mode | Flag | Best for |
|---|---|---|
| BFS (default) | (none) | "What is X connected to?" - broad context, nearest neighbors first |
| DFS | `--dfs` | "How does X reach Y?" - trace a specific chain or dependency path |

Replace `QUESTION`, `MODE` (`bfs` or `dfs`), and `BUDGET` (default `2000`, or `--budget N`):

```bash
$PYTHON -c "
import sys, json
from networkx.readwrite import json_graph
import networkx as nx
from pathlib import Path

data = json.loads(Path('graphify-out/graph.json').read_text())
G = json_graph.node_link_graph(data, edges='links')

question = 'QUESTION'
mode = 'MODE'
terms = [t.lower() for t in question.split() if len(t) > 3]

scored = []
for nid, ndata in G.nodes(data=True):
    label = ndata.get('label', '').lower()
    score = sum(1 for t in terms if t in label)
    if score > 0:
        scored.append((score, nid))
scored.sort(reverse=True)
start_nodes = [nid for _, nid in scored[:3]]

if not start_nodes:
    print('No matching nodes found for query terms:', terms)
    sys.exit(0)

subgraph_nodes = set()
subgraph_edges = []

if mode == 'dfs':
    visited = set()
    stack = [(n, 0) for n in reversed(start_nodes)]
    while stack:
        node, depth = stack.pop()
        if node in visited or depth > 6:
            continue
        visited.add(node)
        subgraph_nodes.add(node)
        for neighbor in G.neighbors(node):
            if neighbor not in visited:
                stack.append((neighbor, depth + 1))
                subgraph_edges.append((node, neighbor))
else:
    frontier = set(start_nodes)
    subgraph_nodes = set(start_nodes)
    for _ in range(3):
        next_frontier = set()
        for n in frontier:
            for neighbor in G.neighbors(n):
                if neighbor not in subgraph_nodes:
                    next_frontier.add(neighbor)
                    subgraph_edges.append((n, neighbor))
        subgraph_nodes.update(next_frontier)
        frontier = next_frontier

token_budget = BUDGET
char_budget = token_budget * 4

def relevance(nid):
    label = G.nodes[nid].get('label', '').lower()
    return sum(1 for t in terms if t in label)

ranked_nodes = sorted(subgraph_nodes, key=relevance, reverse=True)

lines = [f'Traversal: {mode.upper()} | Start: {[G.nodes[n].get(\"label\",n) for n in start_nodes]} | {len(subgraph_nodes)} nodes']
for nid in ranked_nodes:
    d = G.nodes[nid]
    lines.append(f'  NODE {d.get(\"label\", nid)} [src={d.get(\"source_file\",\"\")} loc={d.get(\"source_location\",\"\")}]')
for u, v in subgraph_edges:
    if u in subgraph_nodes and v in subgraph_nodes:
        d = G.edges[u, v]
        lines.append(f'  EDGE {G.nodes[u].get(\"label\",u)} --{d.get(\"relation\",\"\")} [{d.get(\"confidence\",\"\")}]--> {G.nodes[v].get(\"label\",v)}')

output = '\n'.join(lines)
if len(output) > char_budget:
    output = output[:char_budget] + f'\n... (truncated at ~{token_budget} token budget - use --budget N for more)'
print(output)
"
```

Answer based on the subgraph output above. Quote `source_location` when citing a specific fact. If the graph lacks enough information, say so; do not hallucinate edges.

After writing the answer, save it back into the graph:

```bash
$PYTHON -c "
from graphify.ingest import save_query_result
from pathlib import Path
save_query_result(
    question='QUESTION',
    answer='ANSWER',
    memory_dir=Path('graphify-out/memory'),
    query_type='query',
    source_nodes=SOURCE_NODES,
)
print('Query result saved to graphify-out/memory/')
"
```

Replace `ANSWER` with your full answer text and `SOURCE_NODES` with the list of node labels cited.

---

## /graphify path

Find the shortest path between two named concepts.

```bash
$PYTHON -c "
import json, sys
import networkx as nx
from networkx.readwrite import json_graph
from pathlib import Path

data = json.loads(Path('graphify-out/graph.json').read_text())
G = json_graph.node_link_graph(data, edges='links')

a_term = 'NODE_A'
b_term = 'NODE_B'

def find_node(term):
    term = term.lower()
    scored = sorted(
        [(sum(1 for w in term.split() if w in G.nodes[n].get('label','').lower()), n)
         for n in G.nodes()],
        reverse=True
    )
    return scored[0][1] if scored and scored[0][0] > 0 else None

src = find_node(a_term)
tgt = find_node(b_term)

if not src or not tgt:
    print(f'Could not find nodes matching: {a_term!r} or {b_term!r}')
    sys.exit(0)

try:
    path = nx.shortest_path(G, src, tgt)
    print(f'Shortest path ({len(path)-1} hops):')
    for i, nid in enumerate(path):
        label = G.nodes[nid].get('label', nid)
        if i < len(path) - 1:
            edge = G.edges[nid, path[i+1]]
            rel = edge.get('relation', '')
            conf = edge.get('confidence', '')
            print(f'  {label} --{rel}--> [{conf}]')
        else:
            print(f'  {label}')
except nx.NetworkXNoPath:
    print(f'No path found between {a_term!r} and {b_term!r}')
except nx.NodeNotFound as e:
    print(f'Node not found: {e}')
"
```

Explain the path in plain language: what each hop means, why it is significant.

Save back:

```bash
$PYTHON -c "
from graphify.ingest import save_query_result
from pathlib import Path
save_query_result(
    question='Path from NODE_A to NODE_B',
    answer='ANSWER',
    memory_dir=Path('graphify-out/memory'),
    query_type='path_query',
    source_nodes=PATH_NODES,
)
print('Path result saved to graphify-out/memory/')
"
```

---

## /graphify explain

Plain-language explanation of a single node and everything connected to it.

```bash
$PYTHON -c "
import json, sys
import networkx as nx
from networkx.readwrite import json_graph
from pathlib import Path

data = json.loads(Path('graphify-out/graph.json').read_text())
G = json_graph.node_link_graph(data, edges='links')

term = 'NODE_NAME'
term_lower = term.lower()

scored = sorted(
    [(sum(1 for w in term_lower.split() if w in G.nodes[n].get('label','').lower()), n)
     for n in G.nodes()],
    reverse=True
)
if not scored or scored[0][0] == 0:
    print(f'No node matching {term!r}')
    sys.exit(0)

nid = scored[0][1]
data_n = G.nodes[nid]
print(f'NODE: {data_n.get(\"label\", nid)}')
print(f'  source: {data_n.get(\"source_file\",\"unknown\")}')
print(f'  type: {data_n.get(\"file_type\",\"unknown\")}')
print(f'  degree: {G.degree(nid)}')
print()
print('CONNECTIONS:')
for neighbor in G.neighbors(nid):
    edge = G.edges[nid, neighbor]
    nlabel = G.nodes[neighbor].get('label', neighbor)
    rel = edge.get('relation', '')
    conf = edge.get('confidence', '')
    src_file = G.nodes[neighbor].get('source_file', '')
    print(f'  --{rel}--> {nlabel} [{conf}] ({src_file})')
"
```

Write a 3-5 sentence explanation: what this node is, what it connects to, why those connections are significant. Cite source locations.

Save back:

```bash
$PYTHON -c "
from graphify.ingest import save_query_result
from pathlib import Path
save_query_result(
    question='Explain NODE_NAME',
    answer='ANSWER',
    memory_dir=Path('graphify-out/memory'),
    query_type='explain',
    source_nodes=['NODE_NAME'],
)
print('Explanation saved to graphify-out/memory/')
"
```
