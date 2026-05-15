---
name: anaiis-docaudit
description: Audit documentation files for accuracy against the current project state
user-invocable: true
trigger: manual
version: 0.1.0
---

# Documentation Audit

Audit documentation files for accuracy against the current project state.

## Scope
$ARGUMENTS, optional path or glob pattern. Defaults to all of the following files anywhere in the repo:

- `README.md`, `README`, `README.txt`
- `CLAUDE.md`
- `AGENTS.md`
- `CONTRIBUTING.md`, `CONTRIBUTING`
- `LICENSE`, `LICENSE.md`, `LICENSE.txt`
- `CHANGELOG.md`, `CHANGELOG`, `CHANGES.md`, `CHANGES`
- `SECURITY.md`
- `CODEOWNERS`
- `Makefile`, `makefile`, `GNUmakefile`

Use `Glob` with each pattern to discover files; collect all matches before beginning audits. Skip binary LICENSE files (check with `file` if uncertain).

## Tool usage (required, do not deviate)

Follow CLAUDE.md tool preferences exactly:

- **File discovery**: use `Glob`, never `Bash(find)` or `Bash(ls)`
- **Content search**: use `Grep`, never `Bash(grep)` or `Bash(rg)`
- **Reading files**: use `Read` with `offset`/`limit` for large files, never `Bash(cat)`, `Bash(head)`, or `Bash(tail)`
- **File existence checks**: use `Glob` (a hit means it exists; no results means it does not)
- **Bash**: only for things that cannot be done with the above tools, simple, single-purpose commands with no compound brace groups `{ }`, no chained logic inside quotes, and no `echo` with special characters. Examples of acceptable Bash: `make -n <target>`, `cat file | jq '.key'`
- **Parallel calls**: run independent Glob/Grep/Read calls in the same message when they do not depend on each other

## Process

For each documentation file in scope:

### 1. File and path references
- Extract every path mentioned using `Grep` with a pattern like `[a-zA-Z0-9_./\-]+\.(sh|py|R|yaml|toml|lock|md)` or similar
- For each path, use `Glob` to confirm it exists
- Flag any path that returns no Glob results

### 2. Shell commands and Make targets
- Use `Grep` to find shell snippets and `make <target>` references in the doc
- Use `Glob` to confirm the Makefile exists, then use `Grep` on the Makefile to verify each target is defined
- Do not execute commands; only verify they are defined

### 3. Dependency versions
- Use `Grep` to extract version claims from the doc (Python, R, Poetry, etc.)
- Use `Read` (with offset/limit) to check the corresponding lock file or `.python-version` for the actual pinned version
- Compare and flag mismatches

### 4. Architecture and component claims
- Use `Glob` to verify described directories and key files exist
- Use `Grep` to check whether referenced functions, classes, or config keys appear in the codebase
- Flag anything described in docs that has no match in the current codebase

### 5. Stale content
- Flag sections describing removed features, completed migrations, or deprecated workflows, identified by cross-referencing doc claims against what Glob/Grep finds in the actual codebase

### 6. Makefile-specific audit (Makefile, makefile, GNUmakefile only)
- **Target inventory**: use `Grep` with pattern `^[a-zA-Z0-9_-]+:` to extract all defined targets
- **Help text accuracy**: use `Grep` to find a `help` target or `@echo` / `@printf` lines that describe targets; verify each named target in the help output is actually defined
- **`.PHONY` consistency**: extract `.PHONY` declarations and confirm every listed name matches a defined target; flag names declared `.PHONY` that have no corresponding target, and targets that should be `.PHONY` (no output file) but are not declared
- **Path references in recipes**: use `Grep` to find file path references in recipes (strings containing `/` or file extensions); use `Glob` to verify each exists
- **Variable references**: flag variables used in recipes that are not defined in the Makefile and have no obvious environment source (check for `?=` / `:=` / `=` definitions via `Grep`)

## Output

Determine the report directory before writing:
1. Get the repo name: `basename $(git rev-parse --show-toplevel)`
2. Set the output directory: `~/.claude/doc-audits/<repo-name>/`
3. Create it if needed: `mkdir -p ~/.claude/doc-audits/<repo-name>/`
4. Write the report to `~/.claude/doc-audits/<repo-name>/doc-audit-<timestamp>.md`

Do not print the full report to the terminal. Print a one-line summary when done: `N files audited, N issues found (N critical, N minor). Report: <path>`.

Group findings by file. For each issue:
- **File**: path
- **Line/Section**: where the issue is
- **Issue**: what is wrong
- **Suggestion**: how to fix it

End the report with a summary table: N files audited, N issues found, N critical (blocks onboarding), N minor (cosmetic).

Do NOT make changes. Report only. The user will decide what to fix.
