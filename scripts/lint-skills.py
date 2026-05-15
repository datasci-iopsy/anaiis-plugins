"""
Lint SKILL.md files for required frontmatter fields.

Required fields: name, description, user-invocable, trigger, version

Usage:
    python scripts/lint-skills.py
"""

import re
import sys
from pathlib import Path


REQUIRED_FIELDS = {"name", "description", "user-invocable", "trigger", "version"}
VALID_TRIGGERS = {"auto", "manual", "hybrid"}


def parse_frontmatter(text: str) -> dict[str, str] | None:
    match = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    if not match:
        return None
    fields: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            fields[key.strip()] = value.strip()
    return fields


def lint_file(path: Path) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8")
    fm = parse_frontmatter(text)
    if fm is None:
        return ["missing frontmatter block"]
    missing = REQUIRED_FIELDS - set(fm.keys())
    if missing:
        errors.append(f"missing fields: {', '.join(sorted(missing))}")
    trigger = fm.get("trigger", "")
    if trigger and trigger not in VALID_TRIGGERS:
        errors.append(f"invalid trigger '{trigger}'; must be one of {VALID_TRIGGERS}")
    return errors


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    skill_files = sorted(repo_root.glob("*/skills/*/SKILL.md"))
    if not skill_files:
        print("No SKILL.md files found.")
        return

    fail = False
    for path in skill_files:
        errors = lint_file(path)
        rel = path.relative_to(repo_root)
        if errors:
            fail = True
            for err in errors:
                print(f"  FAIL  {rel}: {err}")
        else:
            print(f"  OK    {rel}")

    if fail:
        sys.exit(1)
    else:
        print("\nAll SKILL.md files pass lint.")


if __name__ == "__main__":
    main()
