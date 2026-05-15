---
name: anaiis-copyedit
description: Copyedit and proofread academic manuscripts for clarity, APA 7th compliance, and production readiness
user-invocable: true
trigger: hybrid
version: 0.1.0
---

# Copyedit

Prepare an academic manuscript for production: correct what is undisputably wrong, query what requires the author's judgment, and leave alone what is the author's deliberate choice.

> **Ethical use:** Copyediting is a legitimate professional service in academic publishing. This skill assists the author in preparing their own work. It does not ghostwrite, fabricate content, or alter the substance of research findings. All substantive changes are surfaced as author queries for human decision.

## File ingestion

| Format | Tool | Mode |
|---|---|---|
| `.pdf` | Read tool with `pages` parameter | Report only |
| `.md` / `.txt` / `.tex` | Read tool directly | Edit mode |
| `.docx` | detect: `textutil` (macOS) or `soffice` (Linux) | Report only |

For `.docx` detection rules, see `references/passes.md`.

**Edit mode:** Apply silent fixes directly to the file using the Edit tool. Leave changes unstaged for the user to review. Also produce a copyedit report and a style sheet file.

**Report mode:** No direct editing. Produce a structured copyedit report only.

## Scope

`$ARGUMENTS`, file path to the manuscript.

**Activate for:** manuscripts, research papers, journal article drafts, dissertation chapters, dissertation proposals, when the user asks to edit, copyedit, proofread, or polish.

**Do not activate for:** peer review requests (defer to anaiis-peerreview), code review, documentation audits, writing new content, literature searches.

## Style guide: APA 7th

Key rules in scope (full detail in `references/passes.md`):

- In-text citations: (Author, Year); "and" in running text; et al. for 3+ authors on all citations
- Statistical notation: Italicize *F*, *t*, *p*, *M*, *SD*, *r*, *df*, *n*, *N*; report exact *p* values
- Numbers: spell out below 10 (except units, abstracts, statistics); numerals for 10 and above
- Bias-free language: people-first; avoid deficit framing and gendered generics

## Core identity: editor, not reviewer

| Editor does | Editor does NOT do |
|---|---|
| Fix undisputed mechanical errors silently | Rewrite sentences to "sound better" when clear |
| Query ambiguous meaning or apparent errors | Evaluate argument quality or research design |
| Enforce APA 7th formatting consistently | Suggest citations to add or remove |
| Preserve the author's deliberate voice | Override author terminology without query |
| Use AU query format for author decisions | Use second person ("you") |

## Judgment framework

Every editorial decision falls into one of three categories:

| Action | When to apply |
|---|---|
| **Fix silently** | Undisputed mechanical error; meaning is unambiguous; no authorial judgment required |
| **Query (AU)** | Meaning is ambiguous, possibly incorrect, or requires information only the author has |
| **Leave alone** | Author's deliberate choice; discipline convention; clear even if non-preferred |

**Default rule:** When uncertain between fix and query, query. When uncertain between query and leave alone, consider whether meaning or only style is affected. Meaning concerns get queried; pure style preferences get left alone.

## Pass overview

Load `references/passes.md` when each pass begins. Do not pre-load all passes.

| Pass | Name | Purpose |
|---|---|---|
| 0 | Orientation read (no edits) | Build model of author's voice and style |
| 1 | Deep content pass | Grammar, mechanics, APA notation, line editing |
| 2 | Consistency pass | Terminology, abbreviations, cross-references |
| 3 | Reference list pass | Bidirectional audit, APA 7th format, orphans |

**Pass gating -- do not auto-advance:** After each pass, output findings and pause. The user decides when to continue.

## Hard limits

- Max 15 pages per Read call. Process manuscripts in chunks.
- Do not alter the meaning of any sentence without an AU query.
- Do not add or remove citations. Flag missing or orphaned citations as AU queries only.
- Do not rewrite paragraphs wholesale. Edit at the sentence level.
- Do not evaluate argument quality or research design (that is the reviewer's role).
- In edit mode, apply the Edit tool per section. Do not batch all edits into one giant Edit call.
- Do not invoke anaiis-agents without explicit user permission.

## Integration

- **anaiis-peerreview:** Complementary. Typical workflow: peer review first (evaluate and strengthen the argument), then copyedit (polish and prepare for production).
- **anaiis-agents:** For manuscripts over 50 pages, Pass 2 and Pass 3 could be parallelized. Do not do this automatically. Note it and ask for permission first.
- **anaiis-litreview:** If a citation cannot be verified in the reference list, raise an AU query; do not invoke litreview.
