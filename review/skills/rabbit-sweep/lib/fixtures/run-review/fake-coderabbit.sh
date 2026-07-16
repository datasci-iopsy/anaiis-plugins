#!/usr/bin/env bash
# Fixture stand-in for the coderabbit CLI, used by S10 in smoke.sh via PATH
# shadowing. Set FAKE_CODERABBIT_FIXTURE to the NDJSON file to emit for the
# `review` subcommand; `auth status` always reports authenticated. Set
# FAKE_CODERABBIT_EXIT_CODE to make the `review` subcommand exit non-zero
# after emitting its fixture, simulating the CLI process itself crashing.
set -euo pipefail

case "$1" in
	auth)
		echo '{"authenticated":true}'
		;;
	review)
		cat "$FAKE_CODERABBIT_FIXTURE"
		if [ -n "${FAKE_CODERABBIT_EXIT_CODE:-}" ]; then
			exit "$FAKE_CODERABBIT_EXIT_CODE"
		fi
		;;
	*)
		echo "fake-coderabbit: unknown subcommand $1" >&2
		exit 1
		;;
esac
