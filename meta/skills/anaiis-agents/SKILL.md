---
name: anaiis-agents
description: Orchestrate parallel subagents for comparative analyses, multi-source research, codebase exploration across domains, and any task with independent subtasks that benefit from concurrent execution to minimize wall-clock time
user-invocable: false
trigger: auto
version: 0.1.0
---

# Agent Orchestration

Decompose tasks into parallel subagents when independent subtasks exist. Parallel spawning is the default when Step 1 reveals independent subtasks. Do not ask, do not wait for explicit instruction -- except for expensive exploratory operations (see "During planning" below), where you should prompt the user for a targeted scope before spawning.

## When to activate

Activate when the task matches ANY of these patterns:

| Pattern | Example |
|---|---|
| Comparative analysis (A vs B) | "Compare DuckDB vs pandas on this file", "benchmark three approaches" |
| Multi-file analysis with unrelated sources | "Summarize findings across these 4 reports" |
| Multi-source research with independent angles | "What does the literature say from clinical, statistical, and policy perspectives?" |
| Exploratory pattern search across 3+ unrelated modules | "How do auth, billing, and notifications handle errors?" -- Explore agents |
| Code review of 3+ independent files | "Review auth.py, billing.py, and notifications.py" -- code-reviewer agents, one file per agent (1-2 files: single agent or inline, no parallel spawn needed) |
| Independent setup tasks | "Configure linting, testing, and CI" |
| Explicit parallelism request | "Run these in parallel", "use agents for this" |

Do NOT activate when:

- Task is a single linear thread (one file, one query, one fix)
- Subtasks have serial dependencies (output of A feeds B)
- Entire task fits in under 4 tool calls
- User is asking a question, not requesting work
- Task is file listing, directory inspection, or targeted content search, use Glob, Grep, or Read directly
- Two tasks share the same skill and can be combined into one invocation (e.g., two DuckDB queries -- one heredoc; two litreview topics -- one query with OR conditions)

## Decision framework

### Step 1: Decompose the task

List each subtask and whether it depends on another subtask's output. Independent subtasks (no shared inputs/outputs) are candidates for parallel agents. Dependent subtasks run sequentially inline.

### Step 2: Choose a strategy

| Independent subtask count | Strategy |
|---|---|
| 1 | No agents. Do inline. |
| 2-3 | Spawn parallel subagents |
| 4-5 | Spawn parallel subagents, cap at 5 concurrent |
| 6+ | Batch into 4-5 logical groups, one agent per group |
| Any with mid-execution coordination | Sequential inline. Do not use agents. |

### Step 3: Select model per agent

| Subtask type | Model |
|---|---|
| File reads, schema inspection, grep, row counts | haiku |
| SQL analysis, code review, summarization | sonnet |
| Multi-step reasoning, cross-source synthesis, architectural decisions | opus |

Default to sonnet when uncertain. Use haiku aggressively for gather-and-report tasks -- most subagent work qualifies.

### Step 4: Select subagent type

| Task | subagent_type |
|---|---|
| File/codebase exploration, pattern search, research across files | `Explore` |
| Architecture design, implementation planning | `Plan` |
| Claude Code config, settings, hooks questions | `claude-code-guide` |
| Applying a single CodeRabbit fix | `code-surgeon` (named agent) |
| Reviewing a diff or files for correctness/security | `code-reviewer` (named agent) |
| Security audit of files or diff | `security-auditor` (named agent) |
| Multi-step tasks not covered above | omit subagent_type (general-purpose) |

Never use general-purpose for tasks that Explore covers. Explore has all read tools and is faster for research.

## Spawn protocol

Each agent prompt must include:

1. **One focused task** -- never bundle unrelated work into a single agent
2. **All file paths and context needed** -- agents have no shared memory or state
3. **Expected output format** -- what to return and how to structure it
4. **Scope boundary** -- what not to do (e.g., "read only, do not modify files")
5. **Capture structural findings** -- if an Explore agent surfaces project-level facts needed in future sessions (pipeline architecture, module boundaries, data contracts), save them to project memory after synthesis. Not code patterns, those change. Facts about why the architecture exists.

Keep spawn prompts under 200 words. The main token cost driver is context accumulated during execution, not the prompt size itself.

## Synthesis protocol

After all agents return:

1. Do not paste raw agent output into the response
2. Cross-synthesize: identify agreements, contradictions, and patterns across agents
3. Present a unified answer with attribution (which subtask produced each finding)
4. If an agent returned incomplete results, note it and offer to retry that piece only

## Cost guardrails

- **Prefer subagents over agent teams.** Subagents return summarized results; agent teams maintain full per-agent context with coordination overhead (~7x token cost). Only use agent teams when teammates must communicate mid-task.
- **Cap at 5 parallel agents** per user request.
- **Skip parallelism for short tasks.** If the work would take under 4 sequential tool calls, the token overhead of spawning agents exceeds the benefit.
- **Cap agent depth at 10 tool calls per agent.** If a subtask needs more, it is too broad -- split it or run it inline. For code review, one file = one agent, and the 10-call cap is expected to be sufficient; if a single file requires more than 10 tool calls, review it inline instead.
- **Model down where possible.** Haiku at ~$0.25/MTok vs Sonnet at ~$3/MTok. A gather-and-report agent should never run on Sonnet.

## Planning vs implementation token profiles

Exploration agents are expensive and unbounded. On a large codebase, a single Explore agent can read 30+ files and consume 50k+ tokens because it follows patterns speculatively. Implementation agents are bounded -- they write or edit specific files and cost proportionally less.

**During planning:**
- Prefer targeted Glob and Grep over Explore agents when you know what you're looking for
- Use at most 1-2 Explore agents per planning session, with tightly scoped prompts
- Avoid broad "explore this entire layer" prompts on large codebases because they will read everything
- Prompt the user for targeted searches BEFORE exploring entire layer to avoid reading everything
- Sequential exploration is acceptable; the user's wall-clock patience is not the bottleneck

**During implementation:**
- Parallel agents are justified for genuinely independent file writes/edits (e.g., 3 unrelated models, separate config files)
- Token cost is predictable and bounded by the files being modified

The "thorough planning = cheaper coding" argument breaks down when planning consumes so much of the session budget that implementation cannot proceed. Prefer a leaner plan that can be refined during implementation over an exhaustive plan that exhausts the session.

## Integration with domain skills

This skill provides the orchestration layer. Domain skills provide the expertise. When spawning agents for domain work, reference the skill by name so the agent picks it up from its own context -- do not duplicate domain skill logic in the spawn prompt.

**Rules take precedence over this skill.** If a domain rule specifies that two related queries should be consolidated (e.g., `rules/duckdb.md`: consolidate same-phase scans), do not spawn parallel agents to run them separately.

| Domain | Skill to reference |
|---|---|
| File/data analysis (parquet, CSV, avro, JSON, SQLite) | anaiis-duckdb |
| Literature and document research | anaiis-litreview |
| Environment health checks | anaiis-preflight (run inline, not in an agent) |

**anaiis-preflight** is always run inline before spawning agents. Do not waste an agent on it.
