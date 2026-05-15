"""
Count approximate tokens in each SKILL.md file and flag any over budget.

Token estimate: split on whitespace, multiply by 1.3 (rough chars-to-tokens ratio).
This is a cheap proxy; actual tokenization varies by model.

Usage:
    python scripts/count-skill-tokens.py [--budget 500]
"""

import argparse
import sys
from pathlib import Path


TOKEN_BUDGET = 500


def estimate_tokens(text: str) -> int:
    words = text.split()
    return int(len(words) * 1.3)


def scan(repo_root: Path, budget: int) -> list[tuple[Path, int]]:
    over_budget = []
    skill_files = sorted(repo_root.glob("*/skills/*/SKILL.md"))
    if not skill_files:
        print("No SKILL.md files found.")
        return over_budget
    for path in skill_files:
        tokens = estimate_tokens(path.read_text(encoding="utf-8"))
        status = "OK" if tokens <= budget else "OVER"
        print(f"  {status:4s}  {tokens:4d}t  {path.relative_to(repo_root)}")
        if tokens > budget:
            over_budget.append((path, tokens))
    return over_budget


def main() -> None:
    parser = argparse.ArgumentParser(description="Count SKILL.md token estimates")
    parser.add_argument("--budget", type=int, default=TOKEN_BUDGET)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    print(f"Scanning {repo_root} (budget: {args.budget} tokens)\n")
    over = scan(repo_root, args.budget)

    if over:
        print(
            f"\n{len(over)} file(s) over budget. Trim router content; move detail to references/."
        )
        sys.exit(1)
    else:
        print("\nAll SKILL.md files within budget.")


if __name__ == "__main__":
    main()
