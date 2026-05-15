---
name: anaiis-skillreview
description: "Explicit /anaiis-skillreview, review accumulated session patterns from handoff files and feedback memories; identify recurring corrections and friction; propose concrete updates to rules or skill files. Demand-triggered only. Do NOT auto-trigger."
user-invocable: true
trigger: manual
version: 0.1.0
---

# Skill Review

Translates accumulated session signal into concrete proposals for improving rules and skill files. Uses existing infrastructure, handoff files, feedback memories, git history, with no separate observation log required.

Run this when: a body of work is complete and you want to close the loop; the same correction has recurred; or you want to convert session-level learning into durable rule updates.

## When to activate

Explicit invocation only: `/anaiis-skillreview`

Do NOT auto-trigger on task-oriented sessions, tool use, or agentic work. This skill requires deliberate review time and writes file output.

## Steps

### Step 1, Locate session history

Construct the memory path for the current project:
- CWD with `/` and `.` replaced by `-` gives the project key
- Memory path: `~/.claude/projects/<project-key>/memory/`

Use Glob to find all handoff files in that directory: `handoff_*.md`

Read the most recent 5. From each, extract:
- Files written or edited (Write/Edit operations)
- Git state at compaction time (which rules/skills had pending changes)
- Session timestamp and trigger type (manual vs auto)

If fewer than 2 handoff files exist, note the limited data and produce a minimal report. Do not fabricate patterns from a single session.

### Step 2, Load feedback context

Read all `feedback_*.md` files in the memory directory. These are already-distilled behavioral corrections. For each:
- Note which rule file it corresponds to (if any)
- If the feedback says something already in rules: the rule is working; no change needed
- If the feedback says something NOT in any rule file: that is a gap worth flagging

Read `user_profile.md` if present, use it to calibrate explanation level and context in the proposal.

### Step 3, Check recent git history

```bash
git -C ~/.dotfiles log --oneline -20
```

Note commits that touched `rules/` or `skills/`. Rules/skills with no recent commits may be drifting from actual usage. Rules that were just recently added can be marked as "new, monitor before proposing changes."

### Step 4, Identify patterns

Cross-reference handoff history, feedback memories, and git log. Surface only durable patterns, not one-offs.

**Flag these:**
- The same file or area edited in 3+ sessions -- that area is unstable; a rule may be underspecified
- A feedback memory references something absent from all rule and skill files -- missing documentation
- Git log shows repeated small patches to the same skill file -- structural work needed, not more patches
- A rule was recently written but has not appeared to influence any session (no relevant edits, no corrections avoided) -- monitor; may not be triggering

**Ignore these:**
- Corrections that appear in exactly one session
- Changes to data files, configs, or non-rule/skill content
- Git history entries for bug fixes unrelated to Claude behavior
- Anything already documented in CLAUDE.md

### Step 5, Cross-check existing rules and skills

For each pattern identified, verify whether it is already documented:

Use Grep to search: pattern against `~/.dotfiles/claude/rules/` and `~/.dotfiles/claude/skills/`

Classification:
- **Already covered, rule strong:** no change needed, note it in "No-action items"
- **Already covered, rule weak:** enforcement wording may need strengthening, flag as low priority
- **Not covered:** genuine gap, flag as high or medium priority

### Step 6, Write proposal

Save output to `~/.dotfiles/SKILL-REVIEW-<YYYY-MM-DD>.md`

```markdown
# Skill Review, <date>

## Coverage
- Handoff files reviewed: <N> (<date range>)
- Feedback memories referenced: <list>
- Git commits scanned: last 20

---

## Patterns Identified

### Pattern <N>: <short title>
**Evidence:** <which sessions or memories surfaced this>
**Current documentation:** <rule/skill file and section, or "none">
**Gap:** <what is missing or underspecified>
**Proposed change:** <specific, file path, section heading, new or revised text>
**Priority:** High | Medium | Low

---

## No-action items
Items reviewed and confirmed already covered:
- <rule/skill file>: handles <pattern> adequately, no change needed

---

## Recommended next step
<One concrete action: e.g., "Edit rules/session.md section Tool discipline to add X" or "Build anaiis-Y skill for Z workflow">
```

### Step 7, Report summary

After writing the file, report tersely:
- Handoff files reviewed and date range
- Patterns found (N new gaps, M already covered)
- Path to the proposal file

Do not print the full proposal in terminal. Direct to the file.

## Guardrails

- Never propose a change that duplicates content already present in rules or CLAUDE.md
- Never flag a one-off as a pattern
- Never propose adding a rule for something that has not recurred across multiple sessions
- Output is a proposal only, do not edit rule or skill files during this skill
- If a pattern conflicts with an existing rule, flag the conflict; do not resolve it unilaterally

## Integration

Rules take precedence over skill instructions. If a pattern identified here conflicts with an existing rule, surface the conflict for the user to resolve, not for this skill to decide.

After reviewing the proposal file, the user edits rules/skills directly and commits under normal git discipline (stage by name, one logical concern per commit).
