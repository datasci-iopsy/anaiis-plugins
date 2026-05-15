# anaiis-copyedit: Pass Detail

## File ingestion: .docx detection

1. `command -v textutil` -- macOS: use textutil (built-in, <100ms):
   `textutil -convert txt -stdout "/path/to/file.docx"`, output goes to stdout, no temp file needed.
2. `command -v soffice` -- Linux: use LibreOffice headless:
   ```bash
   TMPDIR=$(mktemp -d)
   soffice --headless --convert-to "txt:Text" --outdir "$TMPDIR" "/path/to/file.docx"
   # Output: $TMPDIR/<filename-stem>.txt, read with Read tool, then rm -rf "$TMPDIR"
   ```
3. Neither found: stop. Report: "No `.docx` converter available. Install LibreOffice: `brew install --cask libreoffice` (macOS) or `sudo apt install libreoffice` (Linux)."

Do not use `python-docx`, `pandoc`, or any other tool.

---

## APA 7th style guide: full rules

- **In-text citations:** (Author, Year) for narrative; (Author & Author, Year) in parenthetical. Use "and" (not &) in running text. Three or more authors: use et al. on all citations.
- **Statistical notation:** Italicize test statistics and descriptive symbols (*F*, *t*, *p*, *M*, *SD*, *r*, *df*, *n*, *N*). Report exact *p* values (e.g., *p* = .034, not *p* < .05) unless *p* < .001.
- **Numbers:** Spell out numbers below 10 (except with units, in abstracts, as statistics). Use numerals for 10 and above, all numbers in the same sentence as a numeral, and all numbers in results sections.
- **Headings:** Level 1 centered bold title case; Level 2 left-aligned bold title case; Level 3 left-aligned bold italic title case; Level 4 indented bold sentence case ending with period; Level 5 indented bold italic sentence case ending with period.
- **Bias-free language:** People-first language; avoid deficit framing and gendered generics.
- **Reference list:** Author, A. A., & Author, B. B. (Year). Title in sentence case. *Journal Name in Title Case*, *Volume*(Issue), pages. https://doi.org/xxxxx

---

## Pass 0: Orientation read (no edits)

Read the full manuscript without making any changes.

1. Read in <=15-page chunks for PDF or <=200-line chunks for .md/.tex.
2. Extract and note: title, section structure, approximate word count, reference count.
3. Observe existing style patterns: terminology in use (record on style sheet), capitalization conventions, abbreviation usage, number formatting, heading format, statistical notation format.
4. Calibrate to the author's register. Academic voice, discipline conventions, and deliberate rhetorical choices must be identified before Pass 1 so they are left alone.
5. Note any immediately visible high-frequency issues (e.g., "APA '&' vs. 'and' error appears throughout").

**Output:** A brief structural summary to the user: title confirmed, mode (edit/report), document structure, any immediately apparent systematic issues. Pause and confirm before proceeding to Pass 1.

---

## Pass 1: Deep content pass

The primary editing pass. Work section by section, applying the judgment framework to every sentence.

Apply to each section:

- **Mechanics:** Grammar, syntax, punctuation, spelling (including homophones and autocorrect artifacts). Fix silently where unambiguous.
- **Line editing (conservative):** Flag genuinely unclear or awkward sentences. Do not flag prose that is merely improvable.
- **Paragraph structure:** Verify each paragraph has a clear topic sentence and that the paragraph delivers on it. Flag misalignment as an AU query rather than rewriting.
- **Transitions:** Flag abrupt transitions or transitional words that contradict the actual logical relationship ("however" where no contrast exists). Query rather than rewrite.
- **Passive voice:** Flag only where it reduces clarity or creates ambiguity. Leave alone in Methods sections where passive is conventional.
- **Hedging and assertion calibration:** Never fix silently. Query where hedging obscures a well-supported finding, or where an unhedged assertion may overreach the data.
- **APA in-text citation format:** Fix silently for format errors (& vs. and, et al. usage, year placement). Query for citation-reference mismatches.
- **Statistical notation:** Fix italicization, spacing, and *p*-value formatting silently. Query apparent numerical discrepancies between text and tables.
- **Table/figure call-outs:** Verify every table and figure is called out in text before its appearance. Flag missing or out-of-order call-outs as AU queries.
- **Heading levels and format:** Fix to APA 7th silently if unambiguous.

In edit mode: apply silent fixes via the Edit tool as you go. Collect all AU queries in a running list.
In report mode: collect all findings categorized by type.

---

## Pass 2: Consistency pass

A dedicated cross-document sweep. These checks require full-manuscript context and must follow Pass 1.

- **Terminological consistency:** Identify every key construct. Flag instances where the same concept is referred to by more than one term, unless variation is deliberate. Query rather than standardize silently.
- **Abbreviation consistency:** Every abbreviation must be defined on first use in the running text and used consistently thereafter. Re-check figures and table captions (which may require re-introduction per APA).
- **Capitalization consistency:** Record decisions on style sheet. Flag inconsistent application.
- **Number formatting:** APA rules. Fix violations silently.
- **Hyphenation consistency:** Compound modifiers before nouns hyphenated; after a linking verb, not hyphenated. Flag inconsistency.
- **Tense consistency:** Past tense for reported results and procedures; present tense for established findings and current discussion. Flag cross-section inconsistencies.
- **Header hierarchy:** Verify that heading levels are used consistently throughout.
- **Cross-reference accuracy:** Check every "as shown in Table N / Figure N" against the actual table/figure numbering. Flag mismatches as AU queries.

---

## Pass 3: Reference list pass

Dedicated pass because references account for ~43% of professional copyediting interventions.

1. **Bidirectional audit:** Every in-text citation must have a reference list entry. Every reference list entry must have at least one in-text citation. List orphans in both directions.
2. **APA 7th reference formatting:**
   - Author names: Last, F. M., & Last, F. M. (Year).
   - Article titles: sentence case
   - Journal names: title case, italicized
   - Volume italicized; issue not italicized: *12*(3)
   - DOI: https://doi.org/xxxxx (not "doi:" prefix; not dx.doi.org)
3. **Et al. audit:** APA 7th requires et al. for all citations with three or more authors, on first and all subsequent citations.
4. **Alphabetical ordering:** Reference list must be alphabetical by first author's surname.
5. **Duplicate detection:** Same source entered twice under different formats.
6. **Missing publication data:** Flag references missing volume, issue, page numbers, or DOI where these should exist.

Fix clear format errors silently where the correct format is unambiguous. Query where author verification is needed.

---

## Output format

### Copyedit report

```
---
## Copyedit Report

**Manuscript:** [title]
**Date:** [date]
**Style guide:** APA 7th
**Mode:** Edit / Report

---

### Summary

[2-3 sentences: overall manuscript quality from a copyediting perspective, scope
of intervention, areas requiring the most work. Not an evaluation of research quality.]

---

### Silent Fixes Applied / Recommended

Grammar: (N)  |  Punctuation: (N)  |  Spelling: (N)  |  APA format: (N)  |  Typography: (N)

[Representative examples if a pattern emerges. Not a complete list of every comma.]

---

### Substantive Edits

[Numbered. Each entry: location, original text, revised text, rationale.]

1. [Section, line N] "..." -> "..." -- [rationale]

---

### Author Queries

[Numbered. AU format. Order of appearance in manuscript.]

AU1: [Section, line N] ...

---

### Reference Audit

- In-text citations with no reference list entry: [list, or "None"]
- Reference list entries with no in-text citation: [list, or "None"]
- Format corrections applied/recommended: (N)

---

### Consistency Notes

[Terminological inconsistencies flagged, capitalization decisions recorded,
abbreviation issues, cross-reference discrepancies.]

---

### Figures and Tables

[Call-out verification results, caption style issues, statistical notation issues.]
---
```

### Author query format

```
AU[N]: [Section, line N or approximate location]
[Query text. States the issue specifically. Offers options if applicable.
Never prescribes. Phrased as a question or request for confirmation.]
```

Examples:
- `AU1: [Methods, line 142] "Participants were excluded if they failed attention checks." How many participants were excluded? APA JARS requires reporting this count in the participants section.`
- `AU2: [Results, line 203] The text reports *p* = .034 for this comparison; Table 2 shows *p* = .062 for the same test. Please verify which value is correct.`

### Style sheet (edit mode: separate file; report mode: appended to report)

```
## Style Sheet: [Manuscript Title]

### Terminology
| Term as used | Notes |
|---|---|

### Abbreviations
| Abbreviation | Full form | First defined |
|---|---|---|

### Capitalization decisions
[e.g., scale names: capitalized; construct names: lowercase]

### Number formatting decisions
[e.g., N = for total sample; n = for subgroups]

### Hyphenation decisions
[e.g., within-person: hyphenated before noun; not hyphenated predicatively]
```

In edit mode, write the style sheet to `<manuscript-stem>-stylesheet.md` in the same directory as the source file.

---

## Academic domain guardrails

- **Causal language:** Query any causal claim ("causes," "leads to," "produces") from a correlational or cross-sectional design. Do not fix; query.
- **Statistical overstatement:** Query phrases like "proves," "confirms," or "demonstrates" where the data are correlational or the sample is non-representative.
- **Construct precision:** Flag when a technical term (e.g., "reliable," "significant," "validate") is used in its casual English sense rather than its psychometric or statistical sense.
- **Level-of-analysis language:** In multilevel studies, flag claims that attribute individual-level findings to group-level phenomena or vice versa.
- **Precision vs. hedging imbalance:** Query over-hedging on well-supported findings and under-hedging on speculative claims. Never fix silently.
