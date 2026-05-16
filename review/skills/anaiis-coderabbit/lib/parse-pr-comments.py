#!/usr/bin/env python3
"""
Normalize raw CodeRabbit PR comments to the anaiis-coderabbit finding NDJSON schema.

Usage:
    uv run parse-pr-comments.py <pr_number> <inline_json> <summary_json> <out_ndjson>

Output schema (one JSON object per line):
    {
        "id":           "PR-<pr>-<comment_id>",
        "file":         "<path or null>",
        "line":         <int or null>,
        "severity":     <1-5>,
        "title":        "<first non-empty line of body>",
        "body":         "<full markdown body>",
        "suggested_fix":"<first code fence content or null>",
        "source":       "pr-inline" | "pr-summary"
    }

Severity inference (deterministic, first match wins):
    Nitpick tag              -> 2
    Refactor suggestion tag  -> 3
    Potential issue tag      -> 4
    Bug / Security tag       -> 5
    No tag + has fix         -> 3
    No tag + no fix          -> 2
"""

import json
import re
import sys

PR_INLINE = "pr-inline"
PR_SUMMARY = "pr-summary"

# Patterns use (?:_|\b) to handle both markdown italic delimiters (_Word_)
# and standalone occurrences. Underscore is a word char so plain \b fails on _Tag_.
TAG_SEVERITY = [
    (
        re.compile(
            r"(?:_|\b)(?:bug|security|critical|vulnerability)(?:_|\b)", re.IGNORECASE
        ),
        5,
    ),
    (re.compile(r"(?:_|\b)potential issue(?:_|\b)", re.IGNORECASE), 4),
    (re.compile(r"(?:_|\b)refactor suggestion(?:_|\b)", re.IGNORECASE), 3),
    (re.compile(r"(?:_|\b)nitpick(?:_|\b)", re.IGNORECASE), 2),
]

CODE_FENCE = re.compile(r"```[^\n]*\n(.*?)```", re.DOTALL)

TITLE_MAX_LEN = 120


def infer_severity(body: str, suggested_fix: str | None) -> int:
    for pattern, sev in TAG_SEVERITY:
        if pattern.search(body):
            return sev
    if suggested_fix is not None:
        return 3
    return 2


def extract_fix(body: str) -> str | None:
    fences = CODE_FENCE.findall(body)
    if not fences:
        return None
    # Prefer a fence that looks like a diff or code suggestion (not just a label)
    for fence in fences:
        stripped = fence.strip()
        if stripped and not stripped.startswith("#"):
            return stripped
    return None


def extract_title(body: str) -> str:
    for line in body.splitlines():
        stripped = line.strip()
        # Skip markdown decorators and empty lines
        if stripped and not stripped.startswith("_") and not stripped.startswith("#"):
            # Trim trailing punctuation for cleanliness
            return stripped[:TITLE_MAX_LEN]
    return body[:TITLE_MAX_LEN].strip()


def normalize(comment: dict, pr: str, source: str) -> dict:
    body = comment.get("body", "")
    suggested_fix = extract_fix(body)
    severity = infer_severity(body, suggested_fix)
    return {
        "id": f"PR-{pr}-{comment['id']}",
        "file": comment.get("path"),
        "line": comment.get("line"),
        "severity": severity,
        "title": extract_title(body),
        "body": body,
        "suggested_fix": suggested_fix,
        "source": source,
    }


def main() -> None:
    if len(sys.argv) != 5:
        print(
            "Usage: parse-pr-comments.py <pr_number> <inline_json> <summary_json> <out_ndjson>",
            file=sys.stderr,
        )
        sys.exit(1)

    pr, inline_path, summary_path, out_path = sys.argv[1:]

    with open(inline_path) as f:
        inline = json.load(f)

    with open(summary_path) as f:
        summary = json.load(f)

    findings = []
    for comment in inline:
        findings.append(normalize(comment, pr, PR_INLINE))
    for comment in summary:
        findings.append(normalize(comment, pr, PR_SUMMARY))

    # Sort: highest severity first, then by source (inline before summary)
    findings.sort(key=lambda x: (-x["severity"], 0 if x["source"] == PR_INLINE else 1))

    with open(out_path, "w") as f:
        for finding in findings:
            f.write(json.dumps(finding) + "\n")

    print(
        f"[parse-pr-comments] {len(findings)} findings written to {out_path}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
