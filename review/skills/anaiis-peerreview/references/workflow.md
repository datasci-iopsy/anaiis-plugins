# anaiis-peerreview: Full Workflow

## File ingestion: .docx detection

**For `.docx`, detect the available converter before proceeding:**

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

## Read 1: First read-through, big picture

*Per Wiley Steps 1-3: form an initial impression, identify major flaws, draft opening assessment.*

1. Read the title, abstract, introduction (first ~5 pages), and conclusion/discussion (last ~5 pages) using the Read tool with `pages` parameter.
2. Map document structure: list all major sections and subsections.
3. Extract and state explicitly:
   - Research questions or hypotheses
   - Stated theoretical framework
   - Study design and primary analyses
   - Claimed contribution(s)
4. Assess: Is the main question interesting, relevant, and original? Are conclusions supported by evidence? (Wiley)
5. Flag any major flaws visible from this initial pass: methodological concerns, conclusions contradicting evidence, overlooked influential factors.
6. **Output a brief structural summary before proceeding**, include what the manuscript does well.

Pause here and confirm the structural summary is accurate before continuing to Read 2.

---

## Read 2: Section-by-section deep review

*Per Wiley Steps 4-5 and APA's assessment structure. Read remaining pages in <=15-page chunks using the `pages` parameter.*

### Introduction / Literature Review

- Does it identify existing knowledge gaps or conflicts in current understanding? (Wiley)
- Does it establish the need for the research? (Wiley)
- Is the theoretical framework clearly identified and appropriate for the research questions?
- Is the literature coverage adequate and current?
- Are hypotheses logically derived from theory, or do they appear post-hoc?
- Is causal logic explicit where applicable?
- Are research aims stated clearly at the introduction's end?

### Method

Apply Wiley's three-criterion framework:

- **Replicable:** Are control conditions, repeated analyses, and adequate sampling present?
- **Repeatable:** Is there sufficient procedural detail for others to replicate the study?
- **Robust:** Are there sufficient data points? Are potential biases addressed?

Additional criteria (APA JARS + I-O specifics):
- Are participants/sample described adequately: demographics, recruitment, inclusion/exclusion criteria, power analysis?
- Are measures validated? Is reliability evidence provided?
- Are constructs operationalized appropriately, formative vs. reflective where relevant?
- Does the analysis plan match the research questions and data structure?
- *For multilevel designs:* Is the nesting structure theoretically justified? Are ICCs reported?
- *For survey studies:* Is common method bias addressed?
- *For longitudinal designs:* Is the time lag theoretically justified?
- *For qualitative work:* Are distinct qualitative standards applied? (APA: see Levitt et al., 2017, *American Psychologist*)

### Results

- Do reported analyses align with the stated hypotheses?
- Are effect sizes and confidence intervals reported per APA 7th?
- Are statistical assumptions checked and reported?
- Are results over-interpreted or under-interpreted?
- Are non-significant findings handled appropriately?
- Do tables and figures effectively support the findings?

### Discussion

- Are interpretations supported by the results actually obtained?
- Are limitations acknowledged honestly and specifically?
- Are practical and theoretical implications distinct?
- Are future directions specific, not generic?
- Does the discussion return to the theoretical framework established in the introduction?

### References

- Do references adequately support the manuscript's claims?
- Are significant similar or opposing studies missing?
- Is the reference list current, well-balanced, and not over-reliant on self-citation?
- Are references retrievable and in APA 7th format?

### For dissertation proposals specifically

- Is the proposed contribution to the field clear and novel?
- Is the proposed method feasible given available resources and timeline?
- Does the proposal demonstrate command of the relevant literature?
- Are the research questions answerable with the proposed design?

---

## Synthesis: Cross-cutting assessment

*Per Wiley Step 6 and APA report structure.*

- **Thread coherence:** Do research questions flow through method -- results -- discussion as a connected argument? Identify any breaks.
- **Internal consistency:** Are claims in the discussion supported by the results? Are key terms used consistently throughout?
- **Writing quality:** Flag paragraph-level coherence issues, jargon overuse, and passive voice density. Do not copy-edit.
- **APA format compliance:** Spot-check headings, citation style, table/figure formatting.
- **EDI considerations (APA):** Does the manuscript use bias-free language? Are participant samples described with inclusion efforts explained? Could any framing harm or stigmatize vulnerable populations?

---

## Output format

**File output:** Write the completed review to `peer-review-<manuscript-stem>-<YYYY-MM-DD>.md` in the current working directory. Print only the file path to terminal, not the full review.

---

**Summary**

[2-3 sentences stating what the manuscript does and what it finds. Then: key strengths, what it does well.]

---

**Dimension Ratings**

Rate each dimension: **Strong** / **Adequate** / **Needs Strengthening**, with a one-line justification.

| Dimension | Rating | Justification |
|---|---|---|
| Significance of the issue addressed | | |
| Contribution of new knowledge to the field | | |
| Quality of research design and analysis | | |
| Adequacy of the data | | |
| Quality of data interpretation | | |
| Coverage and relevance of literature reviewed | | |
| Quality of writing (clarity, organization, style) | | |
| Utility of tables and figures | | |

---

**Major Concerns**

[Numbered list, 5-10 items. Each concern: state the issue, the section and page where it occurs, and a question for the author. These are issues requiring substantial revision before submission.]

---

**Minor Concerns**

[Numbered list, 10-20 items. Cite section headings and specific page/paragraph numbers.]

---

**Questions for the Author**

[Numbered list. Genuine questions probing unclear reasoning, gaps in argument, or missing justification.]

---

**Thread Coherence**

[Brief assessment of whether the RQ -- theory -- method -- results -- discussion chain holds together.]

---

**Overall Impression**

[2-3 sentences on the manuscript's contribution, its readiness, and where effort should be focused. No accept/reject recommendation.]

---

## I-O Psychology and psychometrics guardrails

Apply these checks regardless of whether the manuscript explicitly addresses them:

- **Causal language:** Flag any causal claim from correlational data without acknowledged limitations
- **Construct validity:** Check that reliability, validity evidence, and factor structure are discussed for all primary measures
- **Common method bias:** Flag if survey-based studies do not address CMB
- **Level of analysis:** In multilevel studies, verify that the level of theory matches the level of analysis
- **Time lag justification:** In longitudinal studies, check that the measurement interval is theoretically grounded
- **Scale development:** If measures are developed or adapted, check against *Standards for Educational and Psychological Testing*
- **JARS compliance:** Apply quantitative JARS for quantitative studies; apply qualitative JARS per Levitt et al. (2017) for qualitative work
