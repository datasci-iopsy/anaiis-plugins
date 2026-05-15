---
name: anaiis-litreview
description: Literature review or research synthesis on a topic, auto-triggers when the user asks to find, review, or synthesize literature from the local references catalog
user-invocable: true
trigger: auto
version: 0.1.0
---

# Literature Review

Conduct a focused literature review on a topic, research question, or subdirectory of the references collection.

## When to activate

Activate when the request matches any of these patterns:

| Pattern | Example |
|---|---|
| Topic or keyword literature search | "What does the literature say about burnout?" |
| Research synthesis across sources | "Synthesize the evidence on psychological safety and performance" |
| Subdirectory or domain survey | "Review what I have on power analysis in my references" |
| Gap identification | "What's missing from my literature on multilevel modeling?" |
| Foundational vs. recent literature comparison | "What are the seminal and recent papers on CWB?" |
| Possessive library reference | "What does my library have on X?", "What do I have on psychological safety?", "What's in my corpus on burnout?" |
| Expansion request | "What am I missing on X?", "What else is out there on multilevel modeling?" |

Do NOT activate when:

- The user asks to **edit or copyedit** a manuscript, use anaiis-copyedit
- The user asks to **peer-review** a manuscript draft, use anaiis-peerreview
- The request is a one-off catalog count or schema check, run DuckDB inline, no skill needed
- The user wants a **single specific paper** by author/year, run a targeted DuckDB lookup, no synthesis needed
- The user says "review my literature section" **and provides a manuscript file path**, that is a manuscript section review; use anaiis-peerreview

**Disambiguation:** "Review my literature section" without a file path = catalog gap identification -- activate litreview. With a file path to a manuscript = manuscript section review -- use peerreview.

## Setup detection

Before querying, verify the catalog exists using Glob:

- Check `references_catalog.parquet` in the current working directory (project-specific catalog)
- If not found, check `references_catalog.parquet` in `~/Documents/icloud-docs/prof-edu/references/` (user's main library)
- If both exist, use the current directory version; note: "Using local catalog; main library also available at ~/Documents/icloud-docs/prof-edu/references/"

- **Catalog exists**: proceed with the workflow below
- **Catalog missing**: stop and inform the user. Do not attempt to read PDFs directly at scale.
  Report: "No catalog found. Run `python3 build_catalog.py` in the references directory to build it first."

## Workflow

### Step 1: Query the catalog (DuckDB)

Always query the catalog before reading any PDF. This is the primary narrowing step.

Purpose: **Discovery**, browsing records to find relevant items; user is steering. Per `rules/duckdb.md`: select only columns needed for reasoning, LIMIT 20. Run COUNT first if result set size is uncertain.

```bash
duckdb -json -c "
  SELECT title, authors, year, subdirectory, file_path, abstract
  FROM 'references_catalog.parquet'
  WHERE (
    subdirectory ILIKE '%<topic>%'
    OR title ILIKE '%<keyword>%'
    OR abstract ILIKE '%<keyword>%'
  )
  AND quality_score > 0.4
  ORDER BY year DESC
  LIMIT 20;
"
```

Use the catalog path confirmed by Glob in Setup detection. Adapt the WHERE clause to the user's query. Use multiple ILIKE conditions joined with OR to cast a wider net. If the subdirectory name is known exactly, filter on it directly.

Inspect the results:
- 0 results: broaden the keyword or remove the subdirectory filter
- Fewer than 5 results: proceed with what's found, then offer Step 6 web expansion
- 20 results (at limit): add a more specific filter or restrict to subdirectory
- Target: 8-15 candidate papers to evaluate

### Step 2: Narrow by abstract review (in context, no reads)

From the catalog results, rank candidates based on title, authors, year, and abstract text already returned. Do this reasoning in context, do not read PDFs yet.

Select the 3-5 papers most relevant to the user's specific question. Prefer:
- Papers where the abstract directly addresses the query
- Higher-quality catalog entries (quality_score closer to 1.0)
- More recent papers unless the user asks for foundational or older work

### Step 3: Full-text keyword search (Grep tool, if needed)

If catalog abstracts are insufficient to distinguish candidates, use the Grep tool on extracted `.txt` files:

```
Grep(pattern=<keyword>, path=<subdirectory path>, glob="*.txt", output_mode="files_with_matches")
```

This verifies a specific method, finding, or term appears in the paper body, not just the abstract.

Check with Glob before grepping. If `.txt` files do not exist alongside the PDFs, skip this step, proceed to Step 4, and note to the user: "Full-text keyword search skipped -- no .txt extracts found. Candidate narrowing is based on abstracts only (lower confidence)."

Never use `Bash(rg)` or `Bash(grep)` for this step.

### Step 4: Deep read selected papers (Read tool)

Read only the 3-5 papers selected in Step 2 (or confirmed in Step 3). Use the `pages` parameter for large PDFs:
- Pages 1-3: title, authors, abstract, introduction (orient to argument)
- Pages with methods section: find via page scan if needed
- Final pages: discussion, conclusion, limitations

Hard limit: **5 PDFs per review pass**. If the user needs broader coverage, run a second pass with a refined query.

Respect the read-only analyst role established in the project CLAUDE.md.

### Step 5: Synthesize

After reading, produce a synthesis, not a list of summaries. Structure around themes, agreements, contradictions, and gaps relevant to the user's query.

Cite as: Author(s) (Year), use the catalog `authors` and `year` fields for accuracy.

### Step 6: Web expansion (conditional)

Activate this step when:
- Catalog returned fewer than 5 relevant papers
- User asked for broader coverage ("what else is out there", "what am I missing", "are there more")
- User's query is on a topic they are new to and the catalog is thin

Use WebSearch to find additional papers. For each result:
1. Confirm the DOI (journal articles) or ISBN (books), search CrossRef, Semantic Scholar, publisher page, or Google Scholar
2. Include only results where a DOI or ISBN can be confirmed or reasonably inferred
3. Flag any result where DOI/ISBN cannot be confirmed: "Note: could not confirm DOI, verify before adding to your library"
4. Never fabricate a DOI or ISBN

Per `rules/citations.md`: web results are supplementary. Present them separately from catalog results.

## Output format

```
## Catalog query
[DuckDB query used and row count returned]

## Candidate papers reviewed (from local catalog)
| Title | Authors | Year | DOI/Path |
|---|---|---|---|
| ... | ... | ... | doi or file_path |

## Synthesis
[Thematic synthesis addressing the user's query, citing only catalog-confirmed papers]

## Gaps and next steps
[What the reviewed papers do not cover; suggested follow-up queries or subdirectories]

## Expand your library (web results, if Step 6 ran)
| Title | Authors | Year | DOI / ISBN | Note |
|---|---|---|---|---|
| ... | ... | ... | https://doi.org/... | Relevance note |
```

**File output:** Write the completed synthesis to `litreview-<topic-slug>-<YYYY-MM-DD>.md` in the current working directory. `<topic-slug>`: lowercase the user's query, replace spaces and non-alphanumeric characters with hyphens, collapse runs of hyphens, truncate to 40 characters, trim trailing hyphens (e.g., "burnout" from "What does the literature say about burnout?"; fallback to "topic" if empty). Print only the file path to terminal, not the full synthesis.

## Hard limits

- Never read more than 5 PDFs in a single pass
- Never attempt to read all PDFs in a subdirectory
- Always query the catalog first; never skip to reading
- Do not summarize papers individually, synthesize across them
- Citation integrity: follow `rules/citations.md`. Only cite papers confirmed via catalog query or direct Read. If a source is not in the local catalog, say so and offer a web search only if the user explicitly asks.

## Guardrails

- Query discipline (purpose classification, column selection, re-query prevention): follow `rules/duckdb.md`
- Never use `Bash(rg)` or `Bash(grep)`, use the Grep tool for content search; use Glob for file existence checks
- The catalog query is a Discovery query: limit to columns needed for narrowing (title, authors, year, subdirectory, file_path, abstract); do not add columns that will not drive the selection decision

## Integration

**Rules take precedence over this skill.** If `rules/duckdb.md` or `rules/session.md` conflict with a step below, the rule governs.

| Downstream need | Action |
|---|---|
| Literature gap found, needs investigation | Note in synthesis output; user re-invokes litreview with refined query |
| Literature found, manuscript needs review | User invokes anaiis-peerreview separately; do not bundle |
| 3+ independent topic threads needed in parallel | Use anaiis-agents; each agent handles one topic thread |
