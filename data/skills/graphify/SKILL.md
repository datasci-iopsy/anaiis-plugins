---
name: graphify
description: "EXPLICIT INVOCATION ONLY via /graphify. Build a knowledge graph from a codebase or document corpus. Do not auto-trigger, do not suggest, do not invoke proactively. Only run when the user types /graphify."
user-invocable: true
trigger: manual
version: 0.1.0
---

# /graphify

Turn any folder of files into a navigable knowledge graph with community detection, an honest audit trail, and three outputs: interactive HTML, GraphRAG-ready JSON, and a plain-language GRAPH_REPORT.md.

## What graphify is for

graphify is built around Andrej Karpathy's /raw folder workflow: drop anything into a folder (papers, tweets, screenshots, code, notes) and get a structured knowledge graph that shows you what you did not know was connected.

Three things it does that Claude alone cannot:
1. **Persistent graph**: relationships are stored in `graphify-out/graph.json` and survive across sessions.
2. **Honest audit trail**: every edge is tagged EXTRACTED, INFERRED, or AMBIGUOUS.
3. **Cross-document surprise**: community detection finds connections between concepts in different files that you would never think to ask about directly.

**Supported file types (parsed by tree-sitter AST):** Python, JavaScript, TypeScript, Go, Rust, Java, C, C++, Ruby, C#, Kotlin, Scala, PHP. Plus: Markdown, plain text, PDFs, and images (via Claude vision).

**Not supported:** SQL, YAML, JSON, shell scripts, and other file types not listed above. If the target directory is primarily SQL (e.g. a dbt project), stop and tell the user: "graphify does not parse SQL. For dbt model dependencies, use the dbt manifest.json instead."

## Usage

```
/graphify                                             # full pipeline on current directory
/graphify <path>                                      # full pipeline on specific path
/graphify <path> --mode deep                          # thorough extraction, richer INFERRED edges
/graphify <path> --update                             # incremental: re-extract only new/changed files
/graphify <path> --cluster-only                       # rerun clustering on existing graph
/graphify <path> --no-viz                             # skip visualization, just report + JSON
/graphify <path> --svg                                # also export graph.svg
/graphify <path> --graphml                            # export graph.graphml (Gephi, yEd)
/graphify <path> --neo4j                              # generate graphify-out/cypher.txt for Neo4j
/graphify <path> --neo4j-push bolt://localhost:7687   # push directly to Neo4j
/graphify <path> --mcp                                # start MCP stdio server for agent access
/graphify <path> --watch                              # watch folder, auto-rebuild on code changes
/graphify <path> --wiki                               # build agent-crawlable wiki
/graphify <path> --obsidian                           # write Obsidian vault to graphify-out/obsidian
/graphify <path> --obsidian-dir ~/vaults/my-project   # write vault to custom path
/graphify add <url>                                   # fetch URL, save to ./raw, update graph
/graphify add <url> --author "Name"                   # tag who wrote it
/graphify query "<question>"                          # BFS traversal: broad context
/graphify query "<question>" --dfs                    # DFS: trace a specific path
/graphify query "<question>" --budget 1500            # cap answer at N tokens
/graphify path "AuthModule" "Database"                # shortest path between two concepts
/graphify explain "SwinTransformer"                   # plain-language explanation of a node
```

## Corpus-size guardrails

These run in Step 2 (detect). Do not skip them.

- `total_files == 0` or all file types empty: stop. Unsupported corpus. For SQL/dbt projects, recommend `dbt manifest.json` instead.
- `total_words < 150,000` AND `total_files < 150`: stop. Corpus fits in context. Tell user: "This corpus (~[N] words, [N] files) fits in a single context window. Building a graph costs more tokens than it saves. Use the Explore agent or Read tool directly instead."
- `total_words > 2,000,000` OR `total_files > 200`: warn, show top-5 subdirectories by file count, ask user to pick a subfolder before continuing.
- Otherwise: proceed directly to Step 3.

## How to invoke modes

| What you want | Reference file |
|---|---|
| Build or rebuild a graph (Steps 1-9) | `references/pipeline.md` |
| Query, path, or explain | `references/queries.md` |
| Incremental update, cluster-only, watch, MCP, Neo4j, git hook | `references/incremental.md` |
| Ingest a URL into the corpus | `references/add.md` |

Read only the reference file relevant to the current invocation. Do not pre-load all references.

## Honesty Rules

- Never invent an edge. If unsure, use AMBIGUOUS.
- Never skip the corpus-size check warning.
- Always show token cost in the report.
- Never hide cohesion scores behind symbols: show the raw number.
- Never run HTML viz on a graph with more than 5,000 nodes without warning the user.
