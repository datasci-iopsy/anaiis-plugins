#!/usr/bin/env bash
# Trigger + archive the pr-af engine run (Phase 1). Composes with preflight.sh:
#   preflight.sh --pr <N> | run-af-review.sh [--force]
# Reads preflight's JSON on stdin (url, run_key, archive_exists, head_sha, pr).
#
# pr-af is an ASYNC control-plane job, not a synchronous CLI: a submit is a paid
# ~$1-2 run, so a dropped poll must resume the SAME execution, never resubmit.
# The run dir is the only state (no in-memory retry ladder):
#   <run_dir>/execution.json   written BEFORE polling starts; never deleted on
#                              timeout, so a later invocation resumes instead of
#                              re-submitting.
#   <run_dir>/response.json    verbatim final poll body; written only on success.
#   <run_dir>/timing.json      submitted_at, completed_at, wall_clock_seconds.
#   <run_dir>/meta.json        model, caps, head_sha, pr_url, argv.
#
# Exit codes:
#   0  success -- archived (or skipped because already archived and no --force)
#   1  usage error / malformed stdin JSON
#   2  praf:submit-failed        -- async POST did not return an execution id
#   3  praf:engine-failed        -- execution completed with a failure status
#   4  praf:poll-deadline-exceeded -- execution.json preserved for a later resume
#   5  praf:engine-timeout       -- engine itself reported status=timeout (its own
#                                    inactivity watchdog gave up); this is terminal on
#                                    the server, resuming would poll a dead execution
#                                    forever, so unlike exit 4 this is NOT resumable
set -euo pipefail

CURL="${PRAF_CURL:-curl}"
RUNS_DIR="${PRAF_RUNS_DIR:-$HOME/.pr-af/runs}"
BASE_URL="${PRAF_BASE_URL:-http://localhost:8080}"
MODEL="${PRAF_MODEL:-deepseek/deepseek-v4-flash-0731}"
# Advisory metadata only, recorded into execution.json/meta.json as caps.max_cost_usd
# for audit purposes; never enforced or compared against actual engine spend. The
# response.json schema documented in references/phases.md exposes no cost field to
# check a completed run's real cost against this cap, so a run can exceed it silently.
MAX_COST_USD="${PRAF_MAX_COST_USD:-1.0}"
MAX_DURATION_SECONDS="${PRAF_MAX_DURATION_SECONDS:-3600}"
POLL_SLACK_SECONDS="${PRAF_POLL_SLACK_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${PRAF_POLL_INTERVAL_SECONDS:-15}"

usage() {
	printf 'Usage: preflight.sh --pr <N> | run-af-review.sh [--force]\n' >&2
}

# CAUTION: a bare pipe here only exposes THIS script's exit code -- any of
# preflight.sh's six distinct failure codes (af missing, plane unreachable, node
# missing, gh unavailable, PR not found, PR not open; see its own header) collapses
# into whatever run-af-review.sh exits with instead (e.g. a generic 1 on empty or
# malformed stdin). Callers who need preflight's real exit code should either
# `set -o pipefail` and read `${PIPESTATUS[0]}`, or capture preflight's JSON to a
# variable/temp file, check ITS exit code, then feed it to run-af-review.sh.

FORCE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--force)
			FORCE=1
			shift
			;;
		*)
			usage
			exit 1
			;;
	esac
done

INPUT_JSON="$(cat)"
if ! jq -e . >/dev/null 2>&1 <<<"$INPUT_JSON"; then
	printf 'usage: malformed JSON on stdin (expected preflight.sh output)\n' >&2
	exit 1
fi

PR_URL=$(jq -r '.url // empty' <<<"$INPUT_JSON")
RUN_KEY=$(jq -r '.run_key // empty' <<<"$INPUT_JSON")
ARCHIVE_EXISTS=$(jq -r '.archive_exists // empty' <<<"$INPUT_JSON")
HEAD_SHA=$(jq -r '.head_sha // empty' <<<"$INPUT_JSON")
PR_NUM=$(jq -r '.pr // empty' <<<"$INPUT_JSON")

if [ -z "$PR_URL" ] || [ -z "$RUN_KEY" ]; then
	printf 'usage: stdin JSON missing url/run_key (expected preflight.sh output)\n' >&2
	exit 1
fi

if [ "$ARCHIVE_EXISTS" = "true" ] && [ "$FORCE" -eq 0 ]; then
	printf 'praf:already-archived -- %s already has a verbatim response.json; pass --force to re-run (paid, roughly one to two dollars)\n' "$RUN_KEY" >&2
	exit 0
fi

RUN_DIR="${RUNS_DIR}/${RUN_KEY}"
mkdir -p "$RUN_DIR"

# Self-contained guard, independent of the stdin-supplied ARCHIVE_EXISTS above: a
# standalone invocation (see usage()) builds its own stdin JSON and can pass an
# inaccurate archive_exists field, bypassing that check entirely. Derive the same
# guard directly from the filesystem so a run directory that already holds a verbatim
# response.json can never fall through to submit() again.
if [ -f "${RUN_DIR}/response.json" ] && [ "$FORCE" -eq 0 ]; then
	printf 'praf:already-archived -- %s already has a verbatim response.json; pass --force to re-run (paid, roughly one to two dollars)\n' "$RUN_KEY" >&2
	exit 0
fi

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

extract_execution_id() {
	jq -r '.execution_id // .id // .data.execution_id // empty' <<<"$1"
}

extract_status() {
	jq -r '.status // .state // .execution.status // empty' <<<"$1"
}

submit() {
	local body response exec_id tmp
	body=$(jq -n --arg pr_url "$PR_URL" '{input: {pr_url: $pr_url}}')
	response=$("$CURL" -sS -X POST "${BASE_URL}/api/v1/execute/async/pr-af.review" \
		-H 'Content-Type: application/json' -d "$body") || {
		printf 'praf:submit-failed -- POST to %s/api/v1/execute/async/pr-af.review failed\n' "$BASE_URL" >&2
		exit 2
	}
	exec_id=$(extract_execution_id "$response")
	if [ -z "$exec_id" ]; then
		printf 'praf:submit-failed -- no execution id in response: %s\n' "$response" >&2
		exit 2
	fi
	tmp="${RUN_DIR}/execution.json.tmp"
	jq -n \
		--arg execution_id "$exec_id" \
		--arg submitted_at "$(now_iso)" \
		--argjson submitted_at_epoch "$(now_epoch)" \
		--arg pr_url "$PR_URL" \
		--arg model "$MODEL" \
		--argjson max_cost_usd "$MAX_COST_USD" \
		--argjson max_duration_seconds "$MAX_DURATION_SECONDS" \
		'{execution_id: $execution_id, submitted_at: $submitted_at, submitted_at_epoch: $submitted_at_epoch, pr_url: $pr_url, model: $model, caps: {max_cost_usd: $max_cost_usd, max_duration_seconds: $max_duration_seconds}}' \
		>"$tmp"
	mv "$tmp" "${RUN_DIR}/execution.json"
	echo "$exec_id"
}

if [ -f "${RUN_DIR}/execution.json" ] && [ ! -f "${RUN_DIR}/response.json" ] && [ "$FORCE" -eq 0 ]; then
	EXECUTION_ID=$(jq -r '.execution_id' "${RUN_DIR}/execution.json")
	printf 'praf:resuming -- found execution.json for %s, resuming poll (never resubmitting)\n' "$RUN_KEY" >&2
else
	if [ -f "${RUN_DIR}/execution.json" ] && [ ! -f "${RUN_DIR}/response.json" ]; then
		ABANDONED_EXECUTION_ID=$(jq -r '.execution_id // empty' "${RUN_DIR}/execution.json")
		printf 'praf:abandoning-in-flight -- --force is submitting a new execution while %s (execution_id=%s) may still be running on the engine; it may still complete and charge in addition to this new run\n' "$RUN_KEY" "$ABANDONED_EXECUTION_ID" >&2
	fi
	EXECUTION_ID=$(submit)
fi

SUBMITTED_AT=$(jq -r '.submitted_at' "${RUN_DIR}/execution.json")
SUBMITTED_AT_EPOCH=$(jq -r '.submitted_at_epoch' "${RUN_DIR}/execution.json")
DEADLINE=$((SUBMITTED_AT_EPOCH + MAX_DURATION_SECONDS + POLL_SLACK_SECONDS))

POLL_BODY_FILE="${RUN_DIR}/response.json.tmp"
while :; do
	if "$CURL" -sS "${BASE_URL}/api/v1/executions/${EXECUTION_ID}" >"$POLL_BODY_FILE"; then
		if [ -s "$POLL_BODY_FILE" ]; then
			RAW_RESPONSE=$(cat "$POLL_BODY_FILE")
			STATUS=$(extract_status "$RAW_RESPONSE")
			case "$STATUS" in
				completed | success | succeeded | done)
					break
					;;
				failed | error | cancelled)
					printf 'praf:engine-failed -- execution %s reported status=%s: %s\n' "$EXECUTION_ID" "$STATUS" "$RAW_RESPONSE" >&2
					exit 3
					;;
				timeout)
					printf 'praf:engine-timeout -- execution %s reported status=timeout (engine inactivity watchdog): %s\n' "$EXECUTION_ID" "$RAW_RESPONSE" >&2
					exit 5
					;;
			esac
		fi
	fi
	if [ "$(now_epoch)" -ge "$DEADLINE" ]; then
		printf 'praf:poll-deadline-exceeded -- execution %s still not complete after %ds; execution.json kept for resume\n' \
			"$EXECUTION_ID" "$((MAX_DURATION_SECONDS + POLL_SLACK_SECONDS))" >&2
		exit 4
	fi
	sleep "$POLL_INTERVAL_SECONDS"
done

COMPLETED_AT=$(now_iso)
COMPLETED_AT_EPOCH=$(now_epoch)
mv "$POLL_BODY_FILE" "${RUN_DIR}/response.json"

jq -n \
	--arg submitted_at "$SUBMITTED_AT" \
	--arg completed_at "$COMPLETED_AT" \
	--argjson wall_clock_seconds "$((COMPLETED_AT_EPOCH - SUBMITTED_AT_EPOCH))" \
	'{submitted_at: $submitted_at, completed_at: $completed_at, wall_clock_seconds: $wall_clock_seconds}' \
	>"${RUN_DIR}/timing.json"

jq -n \
	--arg model "$MODEL" \
	--arg pr_url "$PR_URL" \
	--arg head_sha "$HEAD_SHA" \
	--argjson pr "${PR_NUM:-null}" \
	--argjson max_cost_usd "$MAX_COST_USD" \
	--argjson max_duration_seconds "$MAX_DURATION_SECONDS" \
	--arg argv "run-af-review.sh $*" \
	'{model: $model, pr_url: $pr_url, head_sha: $head_sha, pr: $pr, caps: {max_cost_usd: $max_cost_usd, max_duration_seconds: $max_duration_seconds}, argv: $argv}' \
	>"${RUN_DIR}/meta.json"

printf 'praf:archived -- %s\n' "${RUN_DIR}/response.json" >&2
