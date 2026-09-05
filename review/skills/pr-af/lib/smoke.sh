#!/usr/bin/env bash
# Run from the skill root: bash lib/smoke.sh
# Exits 0 if all tests pass.
set -euo pipefail

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${SKILL_ROOT}/lib"
# This skill's dependencies (curl/af/gh) are live command stand-ins, not static data
# files, so tests use inline env-var-driven fake dispatchers (make_fake_curl, fake_af,
# fake_gh, make_fake_gh_reply) rather than the rabbit-sweep-style checked-in
# lib/fixtures/ file convention.
TMP=$(mktemp -d)
PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf '[PASS] %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf '[FAIL] %s\n' "$1"
}

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Shared fake-curl dispatcher for B1/B2/B5 (run-af-review.sh)
#   FAKE_CURL_SUBMIT_FAIL=1     -> POST (submit) fails
#   FAKE_CURL_SUBMIT_RESPONSE   -> raw body returned on POST (default has execution_id)
#   FAKE_CURL_POLL_RESPONSE    -> raw body returned on every GET (poll)
#   CALLS_LOG                   -> every invocation's argv appended, one line each
# ---------------------------------------------------------------------------
make_fake_curl() {
	local path="$1"
	cat >"$path" <<'EOF'
#!/usr/bin/env bash
# NOTE: default JSON bodies are built via a plain assignment, never inlined as
# ${VAR:-{"a":1}} -- bash closes a ${VAR:-word} expansion at the FIRST unescaped
# '}' inside word, so a literal JSON default there leaks a stray trailing '}'.
printf '%s\n' "$*" >>"${CALLS_LOG:-/dev/null}"
is_post=0
for a in "$@"; do
	[ "$a" = "POST" ] && is_post=1
done
if [ "$is_post" = "1" ]; then
	if [ "${FAKE_CURL_SUBMIT_FAIL:-0}" = "1" ]; then
		exit 1
	fi
	default_submit='{"execution_id":"exec-123"}'
	printf '%s' "${FAKE_CURL_SUBMIT_RESPONSE:-$default_submit}"
	exit 0
fi
default_poll='{"execution_id":"exec-123","status":"running"}'
printf '%s' "${FAKE_CURL_POLL_RESPONSE:-$default_poll}"
exit 0
EOF
	chmod +x "$path"
}

# ---------------------------------------------------------------------------
# B1: run-af-review.sh -- idempotency (skip on existing archive; --force re-runs)
# ---------------------------------------------------------------------------
b1() {
	local errors=0
	local script="${LIB}/run-af-review.sh"

	if [ ! -x "$script" ]; then
		fail "B1: run-af-review.sh missing or not executable"
		return
	fi

	local fake_curl="${TMP}/b1-fake-curl"
	make_fake_curl "$fake_curl"

	# B1.1: archive_exists=true, no --force -> skip entirely, exit 0, no curl calls
	local calls_log="${TMP}/b1.1.calls"
	: >"$calls_log"
	local input='{"pr":1,"url":"https://github.com/o/r/pull/1","head_sha":"abc123","run_key":"o-r-pr1-abc123-model","archive_exists":true}'
	set +e
	echo "$input" | CALLS_LOG="$calls_log" PRAF_CURL="$fake_curl" bash "$script" >/dev/null 2>"${TMP}/b1.1.err"
	code=$?
	set -e
	if [ "$code" -ne 0 ] || [ -s "$calls_log" ] || ! grep -q "praf:already-archived" "${TMP}/b1.1.err"; then
		echo "  FAIL B1.1: expected exit 0, no curl calls, praf:already-archived note; got exit ${code}, calls: $(cat "$calls_log"), stderr: $(cat "${TMP}/b1.1.err")"
		errors=$((errors + 1))
	fi

	# B1.2: archive_exists=true, --force -> submits anyway (POST call logged)
	local runs_dir="${TMP}/b1.2-runs"
	calls_log="${TMP}/b1.2.calls"
	: >"$calls_log"
	set +e
	echo "$input" | CALLS_LOG="$calls_log" PRAF_CURL="$fake_curl" PRAF_RUNS_DIR="$runs_dir" \
		FAKE_CURL_POLL_RESPONSE='{"execution_id":"exec-123","status":"completed"}' \
		bash "$script" --force >/dev/null 2>"${TMP}/b1.2.err"
	code=$?
	set -e
	if [ "$code" -ne 0 ] || ! grep -q "POST" "$calls_log"; then
		echo "  FAIL B1.2: expected exit 0 with a POST call under --force; got exit ${code}, calls: $(cat "$calls_log")"
		errors=$((errors + 1))
	fi

	# B1.3: .lock dir pre-held for the run key, no --force -> exit 2, praf:run-locked, no curl call
	local lock_runs_dir="${TMP}/b1.3-runs"
	calls_log="${TMP}/b1.3.calls"
	: >"$calls_log"
	local lock_input='{"pr":1,"url":"https://github.com/o/r/pull/1","head_sha":"abc123","run_key":"o-r-pr1-locked-model","archive_exists":false}'
	mkdir -p "${lock_runs_dir}/o-r-pr1-locked-model/.lock"
	set +e
	echo "$lock_input" | CALLS_LOG="$calls_log" PRAF_CURL="$fake_curl" PRAF_RUNS_DIR="$lock_runs_dir" \
		bash "$script" >/dev/null 2>"${TMP}/b1.3.err"
	code=$?
	set -e
	if [ "$code" -ne 2 ] || [ -s "$calls_log" ] || ! grep -q "praf:run-locked" "${TMP}/b1.3.err"; then
		echo "  FAIL B1.3: expected exit 2, no curl calls, praf:run-locked note; got exit ${code}, calls: $(cat "$calls_log"), stderr: $(cat "${TMP}/b1.3.err")"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "B1: run-af-review.sh idempotency (skip vs. --force)"
	else
		fail "B1: run-af-review.sh idempotency (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# B2: run-af-review.sh -- archive integrity (verbatim, byte-identical response.json)
# ---------------------------------------------------------------------------
b2() {
	local errors=0
	local script="${LIB}/run-af-review.sh"
	local fake_curl="${TMP}/b2-fake-curl"
	make_fake_curl "$fake_curl"

	local runs_dir="${TMP}/b2-runs"
	local calls_log="${TMP}/b2.calls"
	: >"$calls_log"
	local input='{"pr":1,"url":"https://github.com/o/r/pull/1","head_sha":"abc123def456","run_key":"o-r-pr1-abc123def456-model","archive_exists":false}'
	# Deliberately odd whitespace/key order: proves the script never re-serializes.
	local poll_body='{"status": "completed",   "findings":[{"severity":"critical","title":"x"}] , "total_findings":1}'
	set +e
	echo "$input" | CALLS_LOG="$calls_log" PRAF_CURL="$fake_curl" PRAF_RUNS_DIR="$runs_dir" \
		FAKE_CURL_POLL_RESPONSE="$poll_body" \
		bash "$script" >/dev/null 2>"${TMP}/b2.err"
	code=$?
	set -e

	local archived="${runs_dir}/o-r-pr1-abc123def456-model/response.json"
	if [ "$code" -ne 0 ]; then
		echo "  FAIL B2.1: expected exit 0, got ${code}: $(cat "${TMP}/b2.err")"
		errors=$((errors + 1))
	elif [ ! -f "$archived" ]; then
		echo "  FAIL B2.1: response.json not written at ${archived}"
		errors=$((errors + 1))
	elif [ "$(cat "$archived")" != "$poll_body" ]; then
		echo "  FAIL B2.1: response.json not byte-identical to the polled body"
		echo "    got:      $(cat "$archived")"
		echo "    expected: ${poll_body}"
		errors=$((errors + 1))
	fi

	local meta="${runs_dir}/o-r-pr1-abc123def456-model/meta.json"
	local timing="${runs_dir}/o-r-pr1-abc123def456-model/timing.json"
	if [ ! -f "$meta" ] || [ ! -f "$timing" ]; then
		echo "  FAIL B2.2: meta.json/timing.json not written"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "B2: run-af-review.sh archive integrity (verbatim response.json)"
	else
		fail "B2: run-af-review.sh archive integrity (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# B4: preflight.sh -- af/plane/node/PR/CR checks, run-key computation
# ---------------------------------------------------------------------------
b4() {
	local errors=0
	local script="${LIB}/preflight.sh"

	if [ ! -x "$script" ]; then
		fail "B4: preflight.sh missing or not executable"
		return
	fi

	# Fake af dispatcher: FAKE_AF_DOWN=1 -> plane unreachable;
	# FAKE_AF_NODE_FOUND=0 -> plane up but no pr-af reasoner;
	# FAKE_AF_NODE_STOPPED=1 -> plane up with a pr-af reasoner that is not live.
	local fake_af="${TMP}/fake-af"
	cat >"$fake_af" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "ls" ]; then
	if [ "${FAKE_AF_DOWN:-0}" = "1" ]; then
		echo 'Error: Get "http://localhost:8080/api/v1/reasoners": dial tcp [::1]:8080: connect: connection refused' >&2
		exit 3
	fi
	if [ "${FAKE_AF_NODE_STOPPED:-0}" = "1" ]; then
		echo '{"reasoners":[{"node":"pr-af","reasoner":"review_dimension","tags":["review","pr"],"last_run_at":"2026-01-01T00:00:00Z","status":"stopped"}],"shown":1,"total":1}'
	elif [ "${FAKE_AF_NODE_FOUND:-1}" = "1" ]; then
		echo '{"reasoners":[{"node":"pr-af","reasoner":"review_dimension","tags":["review","pr"],"last_run_at":"2026-01-01T00:00:00Z","status":"live"}],"shown":1,"total":1}'
	else
		echo '{"reasoners":[{"node":"other","reasoner":"other_dimension","tags":["other"],"last_run_at":"2026-01-01T00:00:00Z","status":"live"}],"shown":1,"total":1}'
	fi
	exit 0
fi
echo "fake-af: unhandled invocation: $*" >&2
exit 9
EOF
	chmod +x "$fake_af"

	# Fake gh dispatcher, env-var driven per call site:
	#   FAKE_GH_REPO_VIEW_FAIL=1 -> `gh repo view` fails
	#   FAKE_GH_PR_VIEW_FAIL=1   -> `gh pr view` fails
	#   FAKE_GH_STATE            -> PR state (default OPEN)
	#   FAKE_GH_IS_DRAFT         -> true/false (default false)
	#   FAKE_GH_HEAD_SHA         -> head sha (default 12 hex chars, padded)
	#   FAKE_GH_REVIEWS_JSON     -> raw JSON array for `gh api .../reviews`
	local fake_gh="${TMP}/fake-gh"
	cat >"$fake_gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
	exit 0
fi
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
	[ "${FAKE_GH_REPO_VIEW_FAIL:-0}" = "1" ] && exit 1
	echo "${FAKE_GH_REPO:-owner/repo}"
	exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
	[ "${FAKE_GH_PR_VIEW_FAIL:-0}" = "1" ] && exit 1
	cat <<JSON
{"number": 1, "url": "https://github.com/owner/repo/pull/1", "headRefOid": "${FAKE_GH_HEAD_SHA:-abcdef123456789}", "state": "${FAKE_GH_STATE:-OPEN}", "isDraft": ${FAKE_GH_IS_DRAFT:-false}}
JSON
	exit 0
fi
if [ "$1" = "api" ]; then
	echo "${FAKE_GH_REVIEWS_JSON:-[]}"
	exit 0
fi
echo "fake-gh: unhandled invocation: $*" >&2
exit 9
EOF
	chmod +x "$fake_gh"

	local approved_review='[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED"}]'

	# B4.1: usage error on missing --pr
	if PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" bash "$script" >/dev/null 2>&1; then
		echo "  FAIL B4.1: expected non-zero exit with no --pr, got 0"
		errors=$((errors + 1))
	else
		code=$?
		[ "$code" -ne 1 ] && {
			echo "  FAIL B4.1: expected exit 1, got ${code}"
			errors=$((errors + 1))
		}
	fi

	# B4.2: af binary missing -> exit 2
	set +e
	PRAF_AF_BIN="${TMP}/does-not-exist" PRAF_GH="$fake_gh" bash "$script" --pr 1 >/dev/null 2>"${TMP}/b4.2.err"
	code=$?
	set -e
	if [ "$code" -ne 2 ] || ! grep -q "praf:af-missing" "${TMP}/b4.2.err"; then
		echo "  FAIL B4.2: expected exit 2 + praf:af-missing, got exit ${code}: $(cat "${TMP}/b4.2.err")"
		errors=$((errors + 1))
	fi

	# B4.3: gh binary missing -> exit 5
	set +e
	PRAF_AF_BIN="$fake_af" PRAF_GH="${TMP}/does-not-exist" bash "$script" --pr 1 >/dev/null 2>"${TMP}/b4.3.err"
	code=$?
	set -e
	if [ "$code" -ne 5 ] || ! grep -q "praf:gh-unavailable" "${TMP}/b4.3.err"; then
		echo "  FAIL B4.3: expected exit 5 + praf:gh-unavailable, got exit ${code}: $(cat "${TMP}/b4.3.err")"
		errors=$((errors + 1))
	fi

	# B4.4: plane unreachable -> exit 3
	set +e
	FAKE_AF_DOWN=1 PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" bash "$script" --pr 1 >/dev/null 2>"${TMP}/b4.4.err"
	code=$?
	set -e
	if [ "$code" -ne 3 ] || ! grep -q "praf:plane-unreachable" "${TMP}/b4.4.err"; then
		echo "  FAIL B4.4: expected exit 3 + praf:plane-unreachable, got exit ${code}: $(cat "${TMP}/b4.4.err")"
		errors=$((errors + 1))
	fi

	# B4.5: node missing -> exit 4
	set +e
	FAKE_AF_NODE_FOUND=0 PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" bash "$script" --pr 1 >/dev/null 2>"${TMP}/b4.5.err"
	code=$?
	set -e
	if [ "$code" -ne 4 ] || ! grep -q "praf:node-missing" "${TMP}/b4.5.err"; then
		echo "  FAIL B4.5: expected exit 4 + praf:node-missing, got exit ${code}: $(cat "${TMP}/b4.5.err")"
		errors=$((errors + 1))
	fi

	# B4.6: PR not found -> exit 6
	set +e
	FAKE_GH_PR_VIEW_FAIL=1 PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" bash "$script" --pr 1 >/dev/null 2>"${TMP}/b4.6.err"
	code=$?
	set -e
	if [ "$code" -ne 6 ] || ! grep -q "praf:pr-not-found" "${TMP}/b4.6.err"; then
		echo "  FAIL B4.6: expected exit 6 + praf:pr-not-found, got exit ${code}: $(cat "${TMP}/b4.6.err")"
		errors=$((errors + 1))
	fi

	# B4.7: PR closed/merged -> exit 7
	set +e
	FAKE_GH_STATE=MERGED PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" bash "$script" --pr 1 >/dev/null 2>"${TMP}/b4.7.err"
	code=$?
	set -e
	if [ "$code" -ne 7 ] || ! grep -q "praf:pr-not-open" "${TMP}/b4.7.err"; then
		echo "  FAIL B4.7: expected exit 7 + praf:pr-not-open, got exit ${code}: $(cat "${TMP}/b4.7.err")"
		errors=$((errors + 1))
	fi

	# B4.8: CR not ready is advisory, not fatal -- exit 0, stderr note, cr_ready false
	set +e
	out=$(FAKE_GH_REVIEWS_JSON='[]' PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" PRAF_RUNS_DIR="${TMP}/runs-empty" bash "$script" --pr 1 2>"${TMP}/b4.8.err")
	code=$?
	set -e
	cr_ready=$(jq -r '.cr_ready' <<<"$out" 2>/dev/null || echo "PARSE_ERROR")
	if [ "$code" -ne 0 ] || [ "$cr_ready" != "false" ] || ! grep -q "praf:cr-not-ready" "${TMP}/b4.8.err"; then
		echo "  FAIL B4.8: expected exit 0, cr_ready=false, praf:cr-not-ready note; got exit ${code}, cr_ready=${cr_ready}, stderr: $(cat "${TMP}/b4.8.err")"
		errors=$((errors + 1))
	fi

	# B4.9: CR ready true when a completed CodeRabbit review exists
	set +e
	out=$(FAKE_GH_REVIEWS_JSON="$approved_review" PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" PRAF_RUNS_DIR="${TMP}/runs-empty" bash "$script" --pr 1 2>/dev/null)
	code=$?
	set -e
	cr_ready=$(jq -r '.cr_ready' <<<"$out" 2>/dev/null || echo "PARSE_ERROR")
	if [ "$code" -ne 0 ] || [ "$cr_ready" != "true" ]; then
		echo "  FAIL B4.9: expected exit 0, cr_ready=true; got exit ${code}, cr_ready=${cr_ready}"
		errors=$((errors + 1))
	fi

	# B4.10: run key format + archive_exists false when no archive present
	set +e
	out=$(FAKE_GH_REPO="acme/widgets" FAKE_GH_HEAD_SHA="0123456789abcdef" FAKE_GH_REVIEWS_JSON="$approved_review" \
		PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" PRAF_RUNS_DIR="${TMP}/runs-empty" PRAF_MODEL="deepseek/deepseek-v4" \
		bash "$script" --pr 1 2>/dev/null)
	code=$?
	set -e
	run_key=$(jq -r '.run_key' <<<"$out" 2>/dev/null || echo "PARSE_ERROR")
	archive_exists=$(jq -r '.archive_exists' <<<"$out" 2>/dev/null || echo "PARSE_ERROR")
	expected_key="acme-widgets-pr1-0123456789ab-deepseek_deepseek-v4"
	if [ "$code" -ne 0 ] || [ "$run_key" != "$expected_key" ] || [ "$archive_exists" != "false" ]; then
		echo "  FAIL B4.10: expected run_key=${expected_key}, archive_exists=false; got run_key=${run_key}, archive_exists=${archive_exists} (exit ${code})"
		errors=$((errors + 1))
	fi

	# B4.11: archive_exists true when the run dir already has response.json
	local runs_dir="${TMP}/runs-populated"
	mkdir -p "${runs_dir}/acme-widgets-pr1-0123456789ab-deepseek_deepseek-v4"
	echo '{}' >"${runs_dir}/acme-widgets-pr1-0123456789ab-deepseek_deepseek-v4/response.json"
	set +e
	out=$(FAKE_GH_REPO="acme/widgets" FAKE_GH_HEAD_SHA="0123456789abcdef" FAKE_GH_REVIEWS_JSON="$approved_review" \
		PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" PRAF_RUNS_DIR="$runs_dir" PRAF_MODEL="deepseek/deepseek-v4" \
		bash "$script" --pr 1 2>/dev/null)
	code=$?
	set -e
	archive_exists=$(jq -r '.archive_exists' <<<"$out" 2>/dev/null || echo "PARSE_ERROR")
	if [ "$code" -ne 0 ] || [ "$archive_exists" != "true" ]; then
		echo "  FAIL B4.11: expected archive_exists=true; got ${archive_exists} (exit ${code})"
		errors=$((errors + 1))
	fi

	# B4.12: pr-af node present but stopped -> exit 4 (same as node missing)
	set +e
	FAKE_AF_NODE_STOPPED=1 PRAF_AF_BIN="$fake_af" PRAF_GH="$fake_gh" bash "$script" --pr 1 >/dev/null 2>"${TMP}/b4.12.err"
	code=$?
	set -e
	if [ "$code" -ne 4 ] || ! grep -q "praf:node-missing" "${TMP}/b4.12.err"; then
		echo "  FAIL B4.12: expected exit 4 + praf:node-missing, got exit ${code}: $(cat "${TMP}/b4.12.err")"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "B4: preflight.sh af/plane/node/PR/CR checks and run-key computation"
	else
		fail "B4: preflight.sh checks (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# B5: run-af-review.sh -- resume (never resubmit) and poll-deadline-exceeded
# ---------------------------------------------------------------------------
b5() {
	local errors=0
	local script="${LIB}/run-af-review.sh"
	local fake_curl="${TMP}/b5-fake-curl"
	make_fake_curl "$fake_curl"

	# B5.1: execution.json already present, response.json absent -> resume, never
	# submit a second time (no POST in CALLS_LOG), and completes normally on GET.
	local runs_dir="${TMP}/b5.1-runs"
	local run_dir="${runs_dir}/o-r-pr1-aaa111-model"
	mkdir -p "$run_dir"
	jq -n '{execution_id: "exec-resume", submitted_at: "2026-01-01T00:00:00Z", submitted_at_epoch: 1767225600, pr_url: "https://github.com/o/r/pull/1", model: "m", caps: {}}' \
		>"${run_dir}/execution.json"
	local calls_log="${TMP}/b5.1.calls"
	: >"$calls_log"
	local input='{"pr":1,"url":"https://github.com/o/r/pull/1","head_sha":"aaa111","run_key":"o-r-pr1-aaa111-model","archive_exists":false}'
	set +e
	echo "$input" | CALLS_LOG="$calls_log" PRAF_CURL="$fake_curl" PRAF_RUNS_DIR="$runs_dir" \
		FAKE_CURL_POLL_RESPONSE='{"execution_id":"exec-resume","status":"completed"}' \
		bash "$script" >/dev/null 2>"${TMP}/b5.1.err"
	code=$?
	set -e
	if [ "$code" -ne 0 ] || grep -q "POST" "$calls_log" || [ ! -f "${run_dir}/response.json" ]; then
		echo "  FAIL B5.1: expected resume with no POST and a written response.json; got exit ${code}, calls: $(cat "$calls_log")"
		errors=$((errors + 1))
	fi

	# B5.2: poll never completes -> deadline exceeded, execution.json preserved
	local runs_dir2="${TMP}/b5.2-runs"
	calls_log="${TMP}/b5.2.calls"
	: >"$calls_log"
	local input2='{"pr":2,"url":"https://github.com/o/r/pull/2","head_sha":"bbb222","run_key":"o-r-pr2-bbb222-model","archive_exists":false}'
	set +e
	echo "$input2" | CALLS_LOG="$calls_log" PRAF_CURL="$fake_curl" PRAF_RUNS_DIR="$runs_dir2" \
		PRAF_MAX_DURATION_SECONDS=0 PRAF_POLL_SLACK_SECONDS=0 PRAF_POLL_INTERVAL_SECONDS=0 \
		FAKE_CURL_POLL_RESPONSE='{"execution_id":"exec-stuck","status":"running"}' \
		bash "$script" >/dev/null 2>"${TMP}/b5.2.err"
	code=$?
	set -e
	local exec_file="${runs_dir2}/o-r-pr2-bbb222-model/execution.json"
	if [ "$code" -ne 4 ] || ! grep -q "praf:poll-deadline-exceeded" "${TMP}/b5.2.err" || [ ! -f "$exec_file" ]; then
		echo "  FAIL B5.2: expected exit 4 + praf:poll-deadline-exceeded + preserved execution.json; got exit ${code}, exec_file exists: $([ -f "$exec_file" ] && echo yes || echo no), stderr: $(cat "${TMP}/b5.2.err")"
		errors=$((errors + 1))
	fi

	# B5.3: engine reports status=timeout (its own inactivity watchdog) -> this is a
	# distinct terminal outcome from both "completed" and our own poll-deadline-exceeded;
	# regression test for a real bug found in live dogfooding: the case statement used to
	# match neither branch and would poll a dead execution forever.
	local runs_dir3="${TMP}/b5.3-runs"
	calls_log="${TMP}/b5.3.calls"
	: >"$calls_log"
	local input3='{"pr":3,"url":"https://github.com/o/r/pull/3","head_sha":"ccc333","run_key":"o-r-pr3-ccc333-model","archive_exists":false}'
	set +e
	echo "$input3" | CALLS_LOG="$calls_log" PRAF_CURL="$fake_curl" PRAF_RUNS_DIR="$runs_dir3" \
		FAKE_CURL_POLL_RESPONSE='{"execution_id":"exec-timeout","status":"timeout","error":"execution timed out (no activity)"}' \
		bash "$script" >/dev/null 2>"${TMP}/b5.3.err"
	code=$?
	set -e
	if [ "$code" -ne 5 ] || ! grep -q "praf:engine-timeout" "${TMP}/b5.3.err"; then
		echo "  FAIL B5.3: expected exit 5 + praf:engine-timeout on status=timeout; got exit ${code}, stderr: $(cat "${TMP}/b5.3.err")"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "B5: run-af-review.sh resume-not-resubmit, poll-deadline-exceeded, and engine-timeout"
	else
		fail "B5: run-af-review.sh resume/deadline/timeout (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# B6: fetch-cr-threads.sh -- merges inline/pr-summary/review-body + GraphQL state
# ---------------------------------------------------------------------------
b6() {
	local errors=0
	local script="${LIB}/fetch-cr-threads.sh"

	if [ ! -x "$script" ]; then
		fail "B6: fetch-cr-threads.sh missing or not executable"
		return
	fi

	# Fake gh dispatcher, env-var driven per endpoint:
	#   FAKE_GH_INLINE_JSON   -> raw array for pulls/<pr>/comments
	#   FAKE_GH_SUMMARY_JSON  -> raw array for issues/<pr>/comments
	#   FAKE_GH_REVIEWS_JSON  -> raw array for pulls/<pr>/reviews
	#   FAKE_GH_THREADS_JSON  -> raw GraphQL response document
	local fake_gh="${TMP}/b6-fake-gh"
	cat >"$fake_gh" <<'EOF'
#!/usr/bin/env bash
default_threads='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
if [ "$1" = "api" ]; then
	case "$2" in
		*/issues/*/comments)
			printf '%s' "${FAKE_GH_SUMMARY_JSON:-[]}"
			exit 0
			;;
		*/pulls/*/reviews)
			printf '%s' "${FAKE_GH_REVIEWS_JSON:-[]}"
			exit 0
			;;
		*/pulls/*/comments)
			printf '%s' "${FAKE_GH_INLINE_JSON:-[]}"
			exit 0
			;;
		graphql)
			printf '%s' "${FAKE_GH_THREADS_JSON:-$default_threads}"
			exit 0
			;;
	esac
fi
echo "fake-gh: unhandled invocation: $*" >&2
exit 9
EOF
	chmod +x "$fake_gh"

	local bot_comment='[{"id":100,"user":{"login":"coderabbitai[bot]"},"path":"src/a.py","line":10,"body":"finding A"}]'
	local human_comment='[{"id":200,"user":{"login":"someone-else"},"path":"src/b.py","line":5,"body":"not CR"}]'
	local bot_review_body='[{"id":400,"user":{"login":"coderabbitai"},"body":"review-only finding"}]'
	local bot_summary='[{"id":300,"user":{"login":"coderabbitai[bot]"},"body":"walkthrough"}]'
	local thread_with_reply='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"databaseId":100,"author":{"login":"coderabbitai"}},{"databaseId":101,"author":{"login":"alice"}}]}}]}}}}}'

	# B6.1: review-body findings counted when inline is absent (the gap-closer)
	set +e
	out=$(FAKE_GH_INLINE_JSON='[]' FAKE_GH_SUMMARY_JSON='[]' FAKE_GH_REVIEWS_JSON="$bot_review_body" \
		PRAF_GH="$fake_gh" bash "$script" acme/widgets 1 2>"${TMP}/b6.1.err")
	code=$?
	set -e
	count=$(jq '[.[] | select(.source == "review-body")] | length' <<<"$out" 2>/dev/null || echo -1)
	if [ "$code" -ne 0 ] || [ "$count" != "1" ]; then
		echo "  FAIL B6.1: expected exit 0 with 1 review-body finding; got exit ${code}, count=${count}, stderr: $(cat "${TMP}/b6.1.err")"
		errors=$((errors + 1))
	fi

	# B6.2: inline thread state captured (resolved + reply_logins, bot excluded from replies)
	set +e
	out=$(FAKE_GH_INLINE_JSON="$bot_comment" FAKE_GH_SUMMARY_JSON='[]' FAKE_GH_REVIEWS_JSON='[]' \
		FAKE_GH_THREADS_JSON="$thread_with_reply" PRAF_GH="$fake_gh" bash "$script" acme/widgets 1 2>"${TMP}/b6.2.err")
	code=$?
	set -e
	is_resolved=$(jq -r '.[0].is_resolved' <<<"$out" 2>/dev/null)
	reply_logins=$(jq -c '.[0].reply_logins' <<<"$out" 2>/dev/null)
	if [ "$code" -ne 0 ] || [ "$is_resolved" != "true" ] || [ "$reply_logins" != '["alice"]' ]; then
		echo "  FAIL B6.2: expected is_resolved=true, reply_logins=[\"alice\"]; got is_resolved=${is_resolved}, reply_logins=${reply_logins} (exit ${code})"
		errors=$((errors + 1))
	fi

	# B6.3: pr-summary and review-body entries have null thread state
	set +e
	out=$(FAKE_GH_INLINE_JSON='[]' FAKE_GH_SUMMARY_JSON="$bot_summary" FAKE_GH_REVIEWS_JSON="$bot_review_body" \
		PRAF_GH="$fake_gh" bash "$script" acme/widgets 1 2>"${TMP}/b6.3.err")
	code=$?
	set -e
	null_state_ok=$(jq '[.[] | select(.source != "inline") | select(.is_resolved == null and .is_outdated == null and .reply_logins == [])] | length == 2' <<<"$out" 2>/dev/null || echo false)
	if [ "$code" -ne 0 ] || [ "$null_state_ok" != "true" ]; then
		echo "  FAIL B6.3: expected both pr-summary and review-body entries with null thread state; got exit ${code}, out=${out}"
		errors=$((errors + 1))
	fi

	# B6.4: non-CodeRabbit comments/reviews excluded entirely
	local mixed_inline
	mixed_inline=$(jq -c -n --argjson a "$bot_comment" --argjson b "$human_comment" '$a + $b')
	set +e
	out=$(FAKE_GH_INLINE_JSON="$mixed_inline" FAKE_GH_SUMMARY_JSON='[]' FAKE_GH_REVIEWS_JSON='[]' \
		PRAF_GH="$fake_gh" bash "$script" acme/widgets 1 2>"${TMP}/b6.4.err")
	code=$?
	set -e
	total=$(jq 'length' <<<"$out" 2>/dev/null || echo -1)
	has_human=$(jq '[.[] | select(.comment_id == 200)] | length > 0' <<<"$out" 2>/dev/null || echo true)
	if [ "$code" -ne 0 ] || [ "$total" != "1" ] || [ "$has_human" != "false" ]; then
		echo "  FAIL B6.4: expected only the bot comment (length 1, no id 200); got exit ${code}, total=${total}, has_human=${has_human}"
		errors=$((errors + 1))
	fi

	# B6.5: empty everything -> exits 0 with []
	set +e
	out=$(FAKE_GH_INLINE_JSON='[]' FAKE_GH_SUMMARY_JSON='[]' FAKE_GH_REVIEWS_JSON='[]' \
		PRAF_GH="$fake_gh" bash "$script" acme/widgets 1 2>"${TMP}/b6.5.err")
	code=$?
	set -e
	if [ "$code" -ne 0 ] || [ "$out" != "[]" ]; then
		echo "  FAIL B6.5: expected exit 0 with []; got exit ${code}, out=${out}"
		errors=$((errors + 1))
	fi

	# B6.6: bad args -> usage error, exit 1
	set +e
	PRAF_GH="$fake_gh" bash "$script" >/dev/null 2>&1
	code=$?
	set -e
	if [ "$code" -ne 1 ]; then
		echo "  FAIL B6.6: expected exit 1 on missing args; got exit ${code}"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "B6: fetch-cr-threads.sh inline/pr-summary/review-body merge + thread state"
	else
		fail "B6: fetch-cr-threads.sh checks (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# B7: xref.sh -- deterministic file+line join, no model calls
# ---------------------------------------------------------------------------
b7() {
	local errors=0
	local script="${LIB}/xref.sh"

	if [ ! -x "$script" ]; then
		fail "B7: xref.sh missing or not executable"
		return
	fi

	local praf='{"findings":[
		{"severity":"critical","title":"F1","file_path":"a.py","line_start":10,"line_end":10},
		{"severity":"important","title":"F2","file_path":"a.py","line_start":10,"line_end":10},
		{"severity":"suggestion","title":"F3","file_path":"b.py","line_start":20,"line_end":20},
		{"severity":"suggestion","title":"F4","file_path":"c.py","line_start":99,"line_end":99}
	]}'
	local cr='[
		{"comment_id":1,"thread_id":1,"source":"inline","path":"a.py","line":10,"body":"CR root on a.py:10","is_resolved":false,"is_outdated":false,"reply_logins":[]},
		{"comment_id":2,"thread_id":2,"source":"inline","path":"b.py","line":20,"body":"CR root on b.py:20","is_resolved":false,"is_outdated":false,"reply_logins":[]},
		{"comment_id":3,"thread_id":3,"source":"inline","path":"z.py","line":5,"body":"CR root with no praf match","is_resolved":false,"is_outdated":false,"reply_logins":[]},
		{"comment_id":10,"thread_id":300,"source":"pr-summary","path":null,"line":null,"body":"walkthrough","is_resolved":null,"is_outdated":null,"reply_logins":[]},
		{"comment_id":11,"thread_id":null,"source":"review-body","path":null,"line":null,"body":"review body finding","is_resolved":null,"is_outdated":null,"reply_logins":[]}
	]'

	local praf_file="${TMP}/b7-praf.json"
	local cr_file="${TMP}/b7-cr.json"
	printf '%s' "$praf" >"$praf_file"
	printf '%s' "$cr" >"$cr_file"

	# B7.1: known-overlap synthetic corpus -- exact expected output, incl. two
	# findings (F1, F2) matching the same thread, and one finding (F4) with no match.
	local expected='{
		"matched":[
			{"thread_id":1,"cr_summary":"CR root on a.py:10","matched_praf_findings":[
				{"severity":"critical","title":"F1","file_path":"a.py","line_start":10,"line_end":10},
				{"severity":"important","title":"F2","file_path":"a.py","line_start":10,"line_end":10}
			]},
			{"thread_id":2,"cr_summary":"CR root on b.py:20","matched_praf_findings":[
				{"severity":"suggestion","title":"F3","file_path":"b.py","line_start":20,"line_end":20}
			]}
		],
		"cr_unmatched":[{"thread_id":3,"cr_summary":"CR root with no praf match"}],
		"praf_unmatched":[{"severity":"suggestion","title":"F4","file_path":"c.py","line_start":99,"line_end":99}],
		"pr_summary_and_review_body":[
			{"comment_id":10,"thread_id":300,"source":"pr-summary","path":null,"line":null,"body":"walkthrough","is_resolved":null,"is_outdated":null,"reply_logins":[]},
			{"comment_id":11,"thread_id":null,"source":"review-body","path":null,"line":null,"body":"review body finding","is_resolved":null,"is_outdated":null,"reply_logins":[]}
		]
	}'
	set +e
	out=$(bash "$script" "$praf_file" "$cr_file" 2>"${TMP}/b7.1.err")
	code=$?
	set -e
	if [ "$code" -ne 0 ] || [ "$(jq -Sc . <<<"$out")" != "$(jq -Sc . <<<"$expected")" ]; then
		echo "  FAIL B7.1: output did not match expected synthetic corpus result; got exit ${code}"
		echo "    got:      $(jq -Sc . <<<"$out" 2>/dev/null || echo "$out")"
		echo "    expected: $(jq -Sc . <<<"$expected")"
		errors=$((errors + 1))
	fi

	# B7.2: empty findings and empty CR threads -> all four arrays empty, exit 0
	local empty_praf="${TMP}/b7-empty-praf.json"
	local empty_cr="${TMP}/b7-empty-cr.json"
	printf '{"findings":[]}' >"$empty_praf"
	printf '[]' >"$empty_cr"
	set +e
	out=$(bash "$script" "$empty_praf" "$empty_cr" 2>"${TMP}/b7.2.err")
	code=$?
	set -e
	local expected_empty='{"matched":[],"cr_unmatched":[],"praf_unmatched":[],"pr_summary_and_review_body":[]}'
	if [ "$code" -ne 0 ] || [ "$(jq -Sc . <<<"$out")" != "$(jq -Sc . <<<"$expected_empty")" ]; then
		echo "  FAIL B7.2: expected all-empty result on empty inputs; got exit ${code}, out=${out}"
		errors=$((errors + 1))
	fi

	# B7.3: findings present, CR threads empty -> everything lands in praf_unmatched
	set +e
	out=$(bash "$script" "$praf_file" "$empty_cr" 2>"${TMP}/b7.3.err")
	code=$?
	set -e
	praf_unmatched_count=$(jq '.praf_unmatched | length' <<<"$out" 2>/dev/null || echo -1)
	matched_count=$(jq '.matched | length' <<<"$out" 2>/dev/null || echo -1)
	if [ "$code" -ne 0 ] || [ "$praf_unmatched_count" != "4" ] || [ "$matched_count" != "0" ]; then
		echo "  FAIL B7.3: expected 4 praf_unmatched, 0 matched with no CR threads; got exit ${code}, praf_unmatched=${praf_unmatched_count}, matched=${matched_count}"
		errors=$((errors + 1))
	fi

	# B7.4: null file/line fields on findings never crash -- land in praf_unmatched
	local null_praf="${TMP}/b7-null-praf.json"
	printf '{"findings":[{"severity":"suggestion","title":"NoLoc","file_path":null,"line_start":null,"line_end":null},{"severity":"suggestion","title":"NoLine","file_path":"x.py","line_start":null,"line_end":null}]}' >"$null_praf"
	set +e
	out=$(bash "$script" "$null_praf" "$empty_cr" 2>"${TMP}/b7.4.err")
	code=$?
	set -e
	praf_unmatched_count=$(jq '.praf_unmatched | length' <<<"$out" 2>/dev/null || echo -1)
	if [ "$code" -ne 0 ] || [ "$praf_unmatched_count" != "2" ]; then
		echo "  FAIL B7.4: expected exit 0, 2 praf_unmatched for null file/line findings; got exit ${code}, count=${praf_unmatched_count}, stderr: $(cat "${TMP}/b7.4.err")"
		errors=$((errors + 1))
	fi

	# B7.5: usage error on missing args
	set +e
	bash "$script" >/dev/null 2>&1
	code=$?
	set -e
	if [ "$code" -ne 1 ]; then
		echo "  FAIL B7.5: expected exit 1 on missing args; got exit ${code}"
		errors=$((errors + 1))
	fi

	# B7.6: missing input file -> exit 2
	set +e
	bash "$script" "${TMP}/does-not-exist.json" "$empty_cr" >/dev/null 2>"${TMP}/b7.6.err"
	code=$?
	set -e
	if [ "$code" -ne 2 ]; then
		echo "  FAIL B7.6: expected exit 2 on missing input file; got exit ${code}: $(cat "${TMP}/b7.6.err")"
		errors=$((errors + 1))
	fi

	# B7.7: an is_outdated inline entry is excluded from the join -- its thread lands
	# in cr_unmatched and the pr-af finding it would otherwise match lands in
	# praf_unmatched, even though path+line line up.
	local outdated_praf="${TMP}/b7-outdated-praf.json"
	local outdated_cr="${TMP}/b7-outdated-cr.json"
	printf '{"findings":[{"severity":"critical","title":"FX","file_path":"o.py","line_start":15,"line_end":15}]}' >"$outdated_praf"
	printf '[{"comment_id":50,"thread_id":50,"source":"inline","path":"o.py","line":15,"body":"outdated entry","is_resolved":false,"is_outdated":true,"reply_logins":[]}]' >"$outdated_cr"
	set +e
	out=$(bash "$script" "$outdated_praf" "$outdated_cr" 2>"${TMP}/b7.7.err")
	code=$?
	set -e
	matched_count=$(jq '.matched | length' <<<"$out" 2>/dev/null || echo -1)
	cr_unmatched_thread=$(jq -r '.cr_unmatched[0].thread_id' <<<"$out" 2>/dev/null)
	praf_unmatched_title=$(jq -r '.praf_unmatched[0].title' <<<"$out" 2>/dev/null)
	if [ "$code" -ne 0 ] || [ "$matched_count" != "0" ] || [ "$cr_unmatched_thread" != "50" ] || [ "$praf_unmatched_title" != "FX" ]; then
		echo "  FAIL B7.7: expected is_outdated entry excluded from match (0 matched, thread 50 unmatched, FX unmatched); got exit ${code}, matched=${matched_count}, cr_unmatched_thread=${cr_unmatched_thread}, praf_unmatched_title=${praf_unmatched_title}"
		errors=$((errors + 1))
	fi

	# B7.8: two inline comments in the same thread sharing path+line dedupe to a
	# single matched pair via unique_by([idx, thread_id]), not two.
	local dedup_praf="${TMP}/b7-dedup-praf.json"
	local dedup_cr="${TMP}/b7-dedup-cr.json"
	printf '{"findings":[{"severity":"suggestion","title":"FY","file_path":"p.py","line_start":5,"line_end":5}]}' >"$dedup_praf"
	printf '[{"comment_id":60,"thread_id":60,"source":"inline","path":"p.py","line":5,"body":"root reply for p.py:5","is_resolved":false,"is_outdated":false,"reply_logins":[]},{"comment_id":61,"thread_id":60,"source":"inline","path":"p.py","line":5,"body":"reply on p.py:5","is_resolved":false,"is_outdated":false,"reply_logins":[]}]' >"$dedup_cr"
	set +e
	out=$(bash "$script" "$dedup_praf" "$dedup_cr" 2>"${TMP}/b7.8.err")
	code=$?
	set -e
	matched_thread_count=$(jq '.matched | length' <<<"$out" 2>/dev/null || echo -1)
	matched_findings_count=$(jq '.matched[0].matched_praf_findings | length' <<<"$out" 2>/dev/null || echo -1)
	if [ "$code" -ne 0 ] || [ "$matched_thread_count" != "1" ] || [ "$matched_findings_count" != "1" ]; then
		echo "  FAIL B7.8: expected one matched thread with exactly one deduped finding; got exit ${code}, threads=${matched_thread_count}, findings=${matched_findings_count}"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "B7: xref.sh deterministic file+line join"
	else
		fail "B7: xref.sh checks (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# Shared fake-gh dispatcher for B8 (reply-cr.sh's POST-reply endpoint only)
#   FAKE_GH_REPLY_FAIL=1  -> the POST replies call fails
#   CALLS_LOG              -> every invocation's argv appended, one line each
# ---------------------------------------------------------------------------
make_fake_gh_reply() {
	local path="$1"
	cat >"$path" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALLS_LOG:-/dev/null}"
# Guard 7's live is_resolved recheck (api graphql ...) always succeeds here,
# empty stdout -> not resolved -- FAKE_GH_REPLY_FAIL targets the POST call
# specifically, so B8.8 tests "the POST fails", not "the recheck fails".
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
	exit 0
fi
if [ "${FAKE_GH_REPLY_FAIL:-0}" = "1" ]; then
	exit 1
fi
exit 0
EOF
	chmod +x "$path"
}

# ---------------------------------------------------------------------------
# B8: reply-cr.sh -- structural guards, evidence requirement, dry-run, post
# ---------------------------------------------------------------------------
b8() {
	local errors=0
	local script="${LIB}/reply-cr.sh"

	if [ ! -x "$script" ]; then
		fail "B8: reply-cr.sh missing or not executable"
		return
	fi

	local fake_gh="${TMP}/b8-fake-gh"
	make_fake_gh_reply "$fake_gh"

	local threads="${TMP}/b8-threads.json"
	cat >"$threads" <<'EOF'
[
	{"comment_id":1,"thread_id":1,"source":"inline","path":"a.py","line":10,"body":"root","is_resolved":false,"is_outdated":false,"reply_logins":[]},
	{"comment_id":2,"thread_id":2,"source":"inline","path":"b.py","line":20,"body":"root2","is_resolved":true,"is_outdated":false,"reply_logins":[]},
	{"comment_id":3,"thread_id":3,"source":"inline","path":"c.py","line":30,"body":"root3","is_resolved":false,"is_outdated":false,"reply_logins":["some-bot-account"]},
	{"comment_id":10,"thread_id":300,"source":"pr-summary","path":null,"line":null,"body":"walkthrough","is_resolved":null,"is_outdated":null,"reply_logins":[]},
	{"comment_id":11,"thread_id":null,"source":"review-body","path":null,"line":null,"body":"review body finding","is_resolved":null,"is_outdated":null,"reply_logins":[]}
]
EOF

	local body_with_evidence="${TMP}/b8-body-evidence.txt"
	printf 'Confirmed: SQL injection at a.py:10, matches pr-af evidence.\n' >"$body_with_evidence"
	local body_no_evidence="${TMP}/b8-body-no-evidence.txt"
	printf 'This looks fine to me.\n' >"$body_no_evidence"
	local body_wrong_path_evidence="${TMP}/b8-body-wrong-path-evidence.txt"
	printf 'Confirmed: SQL injection at src/api/users.py:42, matches pr-af evidence.\n' >"$body_wrong_path_evidence"

	# B8.1: already-replied refusal (acting_login in reply_logins) -> exit 10, no gh call
	local calls_log="${TMP}/b8.1.calls"
	: >"$calls_log"
	set +e
	CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 3 "$body_with_evidence" "$threads" "some-bot-account" \
		>/dev/null 2>"${TMP}/b8.1.err"
	code=$?
	set -e
	if [ "$code" -ne 10 ] || [ -s "$calls_log" ]; then
		echo "  FAIL B8.1: expected exit 10 and no gh call for already-replied thread; got exit ${code}, calls=$(cat "$calls_log" 2>/dev/null)"
		errors=$((errors + 1))
	fi

	# B8.2: pr-summary source refusal -> exit 10, no gh call
	calls_log="${TMP}/b8.2.calls"
	: >"$calls_log"
	set +e
	CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 10 "$body_with_evidence" "$threads" "me" \
		>/dev/null 2>"${TMP}/b8.2.err"
	code=$?
	set -e
	if [ "$code" -ne 10 ] || [ -s "$calls_log" ]; then
		echo "  FAIL B8.2: expected exit 10 and no gh call for pr-summary thread; got exit ${code}"
		errors=$((errors + 1))
	fi

	# B8.3: review-body source refusal -> exit 10, no gh call
	calls_log="${TMP}/b8.3.calls"
	: >"$calls_log"
	set +e
	CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 11 "$body_with_evidence" "$threads" "me" \
		>/dev/null 2>"${TMP}/b8.3.err"
	code=$?
	set -e
	if [ "$code" -ne 10 ] || [ -s "$calls_log" ]; then
		echo "  FAIL B8.3: expected exit 10 and no gh call for review-body thread; got exit ${code}"
		errors=$((errors + 1))
	fi

	# B8.4: resolved-thread refusal -> exit 10, no gh call
	calls_log="${TMP}/b8.4.calls"
	: >"$calls_log"
	set +e
	CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 2 "$body_with_evidence" "$threads" "me" \
		>/dev/null 2>"${TMP}/b8.4.err"
	code=$?
	set -e
	if [ "$code" -ne 10 ] || [ -s "$calls_log" ]; then
		echo "  FAIL B8.4: expected exit 10 and no gh call for resolved thread; got exit ${code}"
		errors=$((errors + 1))
	fi

	# B8.5: missing-evidence-citation refusal -> exit 10 (Guard 5's intentional
	# no-op, matching every other deliberate-skip guard's convention), no gh call
	calls_log="${TMP}/b8.5.calls"
	: >"$calls_log"
	set +e
	CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 1 "$body_no_evidence" "$threads" "me" \
		>/dev/null 2>"${TMP}/b8.5.err"
	code=$?
	set -e
	if [ "$code" -ne 10 ] || [ -s "$calls_log" ]; then
		echo "  FAIL B8.5: expected exit 10 and no gh call for missing evidence citation; got exit ${code}"
		errors=$((errors + 1))
	fi

	# B8.6: --dry-run posts nothing -> exit 0, prints body, CALLS_LOG stays empty
	calls_log="${TMP}/b8.6.calls"
	: >"$calls_log"
	set +e
	out=$(CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 1 "$body_with_evidence" "$threads" "me" --dry-run 2>"${TMP}/b8.6.err")
	code=$?
	set -e
	if [ "$code" -ne 0 ] || [ -s "$calls_log" ] || [ "$out" != "$(cat "$body_with_evidence")" ]; then
		echo "  FAIL B8.6: expected exit 0, no gh call, and printed body for --dry-run; got exit ${code}, calls=$(cat "$calls_log" 2>/dev/null)"
		errors=$((errors + 1))
	fi

	# B8.7: successful post -> exit 0, exactly two gh calls (Guard 7's live
	# is_resolved recheck, then the POST), recheck strictly before POST, right
	# endpoint/body. NOTE: the recheck call's logged argv embeds reply-cr.sh's
	# multi-line GraphQL query verbatim, so that one call spans several physical
	# lines in $calls_log -- count/order by lines starting "api " (the first
	# token gh is always invoked with here), never by wc -l.
	calls_log="${TMP}/b8.7.calls"
	: >"$calls_log"
	set +e
	CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 1 "$body_with_evidence" "$threads" "me" \
		>/dev/null 2>"${TMP}/b8.7.err"
	code=$?
	set -e
	local call_count graphql_line post_line
	call_count=$(grep -c '^api ' "$calls_log" || true)
	graphql_line=$( (grep -n '^api graphql' "$calls_log" || true) | head -1 | cut -d: -f1)
	post_line=$( (grep -n '^api repos/acme/widgets/pulls/1/comments/1/replies' "$calls_log" || true) | head -1 | cut -d: -f1)
	if [ "$code" -ne 0 ] || [ "$call_count" -ne 2 ] \
		|| [ -z "$graphql_line" ] || [ -z "$post_line" ] || [ "$graphql_line" -ge "$post_line" ] \
		|| ! grep -q 'repos/acme/widgets/pulls/1/comments/1/replies' "$calls_log" \
		|| ! grep -q 'POST' "$calls_log" \
		|| ! grep -qF 'a.py:10' "$calls_log"; then
		echo "  FAIL B8.7: expected exactly one graphql recheck call followed by one POST to the reply endpoint with the evidence body; got exit ${code}, call_count=${call_count}, graphql_line=${graphql_line}, post_line=${post_line}, calls:"
		cat "$calls_log" 2>/dev/null | sed 's/^/    /'
		errors=$((errors + 1))
	fi

	# B8.8: post-failed -> exit 2 (shimmed gh failure)
	calls_log="${TMP}/b8.8.calls"
	: >"$calls_log"
	set +e
	FAKE_GH_REPLY_FAIL=1 CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 1 "$body_with_evidence" "$threads" "me" \
		>/dev/null 2>"${TMP}/b8.8.err"
	code=$?
	set -e
	if [ "$code" -ne 2 ]; then
		echo "  FAIL B8.8: expected exit 2 on gh post failure; got exit ${code}: $(cat "${TMP}/b8.8.err")"
		errors=$((errors + 1))
	fi

	# B8.9: thread id not found in thread-state file -> exit 1, no gh call
	calls_log="${TMP}/b8.9.calls"
	: >"$calls_log"
	set +e
	CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 999 "$body_with_evidence" "$threads" "me" \
		>/dev/null 2>"${TMP}/b8.9.err"
	code=$?
	set -e
	if [ "$code" -ne 1 ] || [ -s "$calls_log" ]; then
		echo "  FAIL B8.9: expected exit 1 and no gh call for unknown thread id; got exit ${code}"
		errors=$((errors + 1))
	fi

	# B8.10: bot-self-reply refusal -- acting_login matches the bot regex even
	# though it is NOT in reply_logins (fetch-cr-threads.sh never puts it there)
	# -> exit 10, reply-cr:already-replied, no gh call
	calls_log="${TMP}/b8.10.calls"
	: >"$calls_log"
	set +e
	CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 1 "$body_with_evidence" "$threads" "coderabbitai[bot]" \
		>/dev/null 2>"${TMP}/b8.10.err"
	code=$?
	set -e
	if [ "$code" -ne 10 ] || [ -s "$calls_log" ] || ! grep -q "reply-cr:already-replied" "${TMP}/b8.10.err"; then
		echo "  FAIL B8.10: expected exit 10, no gh call, reply-cr:already-replied for the bot's own login; got exit ${code}, stderr: $(cat "${TMP}/b8.10.err" 2>/dev/null), calls=$(cat "$calls_log" 2>/dev/null)"
		errors=$((errors + 1))
	fi

	# B8.11: Guard 7's live is_resolved recheck overrides a stale "not resolved"
	# snapshot -- THREAD_STATE_FILE says is_resolved:false for thread 1, but the
	# live graphql recheck reports isResolved:true for that same thread, so the
	# call must refuse (exit 10, reply-cr:thread-resolved) and never reach the
	# POST, proving the recheck actually overrides the snapshot rather than
	# merely existing as dead code. Uses a dedicated fake gh (distinct from
	# fake_gh's fixed reply-only behavior above) that answers `api graphql` with
	# a resolved thread and behaves like the normal reply dispatcher otherwise.
	local fake_gh_live_resolved="${TMP}/b8-fake-gh-live-resolved"
	cat >"$fake_gh_live_resolved" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALLS_LOG:-/dev/null}"
default_graphql='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
	printf '%s' "${FAKE_GH_LIVE_GRAPHQL_JSON:-$default_graphql}"
	exit 0
fi
exit 0
EOF
	chmod +x "$fake_gh_live_resolved"
	local live_resolved_json='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"comments":{"nodes":[{"databaseId":1}]}}]}}}}}'
	calls_log="${TMP}/b8.11.calls"
	: >"$calls_log"
	set +e
	FAKE_GH_LIVE_GRAPHQL_JSON="$live_resolved_json" CALLS_LOG="$calls_log" PRAF_GH="$fake_gh_live_resolved" \
		bash "$script" acme/widgets 1 1 "$body_with_evidence" "$threads" "reviewer2" \
		>/dev/null 2>"${TMP}/b8.11.err"
	code=$?
	set -e
	if [ "$code" -ne 10 ] || ! grep -q "reply-cr:thread-resolved" "${TMP}/b8.11.err" \
		|| grep -q '^api repos/.*replies' "$calls_log"; then
		echo "  FAIL B8.11: expected exit 10 + reply-cr:thread-resolved from the live recheck overriding a stale not-resolved snapshot, no POST issued; got exit ${code}, stderr: $(cat "${TMP}/b8.11.err" 2>/dev/null), calls:"
		cat "$calls_log" 2>/dev/null | sed 's/^/    /'
		errors=$((errors + 1))
	fi

	# B8.12: wrong-path-evidence refusal -- body cites a real-looking file:line
	# that is not the thread's own path ("src/api/users.py:42" for thread 1,
	# whose path is "a.py") -> exit 10, no gh call, mirroring B8.5
	calls_log="${TMP}/b8.12.calls"
	: >"$calls_log"
	set +e
	CALLS_LOG="$calls_log" PRAF_GH="$fake_gh" \
		bash "$script" acme/widgets 1 1 "$body_wrong_path_evidence" "$threads" "me" \
		>/dev/null 2>"${TMP}/b8.12.err"
	code=$?
	set -e
	if [ "$code" -ne 10 ] || [ -s "$calls_log" ]; then
		echo "  FAIL B8.12: expected exit 10 and no gh call for evidence citing a path other than the thread's own; got exit ${code}"
		errors=$((errors + 1))
	fi

	if [ "$errors" -eq 0 ]; then
		pass "B8: reply-cr.sh guards (incl. bot-self-reply, live resolution recheck), evidence requirement, dry-run, and post"
	else
		fail "B8: reply-cr.sh checks (${errors} checks failed)"
	fi
}

# ---------------------------------------------------------------------------
# Runner -- append new bN calls here as later tasks land
# ---------------------------------------------------------------------------
b1
b2
b4
b5
b6
b7
b8

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
