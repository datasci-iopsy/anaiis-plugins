#!/usr/bin/env bash
# Detect the test runner for the current project.
# Prints the test command(s) to run, one per line, or "none" if no suite found.
# Run from the project root (or pass the root as $1).
#
# Precedence: an aggregate runner (tests/run-all.sh) or a Makefile test
# target, if present, is authoritative and printed alone. Only when neither
# exists do the per-ecosystem checks below run (any number of which may
# match, e.g. a repo with both a Python and a Node test suite).

set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Aggregate runner: subsumes ecosystem-specific detection below.
if [ -x "$ROOT/tests/run-all.sh" ] || [ -f "$ROOT/tests/run-all.sh" ]; then
	echo "bash tests/run-all.sh"
	exit 0
fi

# Makefile test target.
if [ -f "$ROOT/Makefile" ] && grep -qE '^test[[:space:]]*:' "$ROOT/Makefile"; then
	echo "make test"
	exit 0
fi

found=0

# R: non-package layout with a tests/testthat/ directory but no DESCRIPTION
# (testthat::test_dir(), not devtools::test() which requires a package).
if [ ! -f "$ROOT/DESCRIPTION" ] && [ -d "$ROOT/tests/testthat" ]; then
	echo "Rscript --no-init-file -e \"testthat::test_dir('tests/testthat')\""
	found=1
fi

# Python: uv-managed project with pytest
if [ -f "$ROOT/pyproject.toml" ] && [ -f "$ROOT/uv.lock" ]; then
	if grep -q "\[tool\.pytest" "$ROOT/pyproject.toml" 2>/dev/null \
		|| [ -d "$ROOT/tests" ] || find "$ROOT" -maxdepth 2 -name "test_*.py" -quit 2>/dev/null | grep -q .; then
		echo "uv run pytest"
		found=1
	fi
fi

# R: devtools-style package with tests/ directory
if [ -f "$ROOT/DESCRIPTION" ] && [ -d "$ROOT/tests" ]; then
	echo "Rscript --no-init-file -e \"devtools::test()\""
	found=1
fi

# Node / Bun: package.json with a test script
if [ -f "$ROOT/package.json" ]; then
	if jq -e '.scripts.test // empty' "$ROOT/package.json" >/dev/null 2>&1; then
		if command -v bun >/dev/null 2>&1 && { [ -f "$ROOT/bun.lock" ] || [ -f "$ROOT/bun.lockb" ]; }; then
			echo "bun test"
		else
			echo "npm test"
		fi
		found=1
	fi
fi

if [ "$found" -eq 0 ]; then
	echo "none"
fi
