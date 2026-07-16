#!/usr/bin/env bash
# Shared ledger helpers for rabbit-sweep.
# Source this file; do not execute directly.
# All functions write to $LEDGER (must be set by caller).

LEDGER_DIR="${HOME}/.claude/rabbit-sweep/runs"
# One-time migration from the pre-rename location; preserves run history
# and PR-mode idempotency (ledger_handled_ids scans this directory).
if [ -d "${HOME}/.claude/anaiis-coderabbit" ] && [ ! -e "${HOME}/.claude/rabbit-sweep" ]; then
	mv "${HOME}/.claude/anaiis-coderabbit" "${HOME}/.claude/rabbit-sweep"
fi

ledger_init() {
	local branch="$1" base="$2" mode="$3"
	mkdir -p "$LEDGER_DIR"
	local iso
	iso=$(date -u +%Y%m%dT%H%M%SZ)
	local safe_branch="${branch//\//-}"
	local suffix=0 candidate
	while :; do
		candidate="${LEDGER_DIR}/${safe_branch}-${iso}${suffix:+-${suffix}}.jsonl"
		if (
			set -o noclobber
			: >"$candidate"
		) 2>/dev/null; then
			LEDGER="$candidate"
			break
		fi
		suffix=$((suffix + 1))
	done
	jq -nc --arg branch "$branch" --arg base "$base" --arg mode "$mode" --arg ts "$iso" \
		'{event:"review_started", branch:$branch, base:$base, mode:$mode, ts:$ts}' >>"$LEDGER"
	export LEDGER
	# Pointer file (no .jsonl suffix, so ledger_handled_ids never scans it):
	# lets a later, separate shell process re-resolve $LEDGER for this branch
	# via ledger_resume, since exported vars do not survive across the Bash
	# tool's separate process invocations.
	printf '%s' "$LEDGER" >"${LEDGER_DIR}/.current-${safe_branch}"
}

# Re-resolves $LEDGER in a shell process that did not run ledger_init itself.
# Usage: ledger_resume [branch]  (defaults to the current git branch)
ledger_resume() {
	local branch="${1:-$(git branch --show-current 2>/dev/null)}"
	local safe_branch="${branch//\//-}"
	local pointer="${LEDGER_DIR}/.current-${safe_branch}"
	if [ ! -f "$pointer" ]; then
		printf 'ledger_resume: no ledger pointer for branch "%s" -- run ledger_init first\n' "$branch" >&2
		return 1
	fi
	LEDGER=$(<"$pointer")
	if [ ! -f "$LEDGER" ]; then
		printf 'ledger_resume: pointer names "%s" but that ledger file does not exist\n' "$LEDGER" >&2
		return 1
	fi
	export LEDGER
}

# Refuses to proceed if $LEDGER is unset/empty, instead of blind-appending to
# a variable that a fresh shell process never inherited (issue: exported vars
# from ledger_init do not persist across separate Bash tool calls).
_ledger_require() {
	if [ -n "${LEDGER:-}" ]; then
		return 0
	fi
	printf 'ledger.sh: $LEDGER is unset in this shell -- run: source lib/ledger.sh && ledger_resume\n' >&2
	return 1
}

ledger_append() {
	_ledger_require || return 1
	printf '%s\n' "$1" >>"$LEDGER"
}

_ledger_event() {
	_ledger_require || return 1
	jq -nc "$@" >>"$LEDGER"
}

ledger_skip() {
	local id="$1" severity="$2" rationale="$3"
	_ledger_event --arg id "$id" --argjson sev "$severity" --arg rat "$rationale" \
		'{event:"skip", id:$id, severity:$sev, rationale:$rat}'
}

# requires_verify (5th arg, "true"|"false") records whether Phase 5 must obtain
# a passing intent-verifier result before this finding may be marked
# intent_verified. Mandatory when decision="fix" -- a "fix" logged with no
# stated requirement is a caller bug (see ledger_intent_verified's guard),
# not a case that should silently default to "no verification needed".
ledger_decision() {
	local id="$1" severity="$2" decision="$3" rationale="$4" requires_verify="${5:-}"
	if [ "$decision" = "fix" ] && [ -z "$requires_verify" ]; then
		printf 'ledger_decision: requires_verify (5th arg, true|false) is mandatory when decision="fix"\n' >&2
		return 1
	fi
	requires_verify="${requires_verify:-false}"
	_ledger_event --arg id "$id" --argjson sev "$severity" --arg dec "$decision" --arg rat "$rationale" --argjson rv "$requires_verify" \
		'{event:"decision", id:$id, severity:$sev, decision:$dec, rationale:$rat, requires_verify:$rv}'
}

ledger_verified() {
	local id="$1"
	_ledger_event --arg id "$id" '{event:"verified", id:$id}'
}

# Records that this finding's fix was committed with no test suite detected
# (detect-tests.sh returned "none"); verification relied on the intent check
# alone. Logged alongside ledger_verified, not instead of it.
ledger_no_tests() {
	local id="$1"
	_ledger_event --arg id "$id" '{event:"no_tests", id:$id}'
}

ledger_verify_failed() {
	local id="$1" file="$2" reason="$3"
	_ledger_event --arg id "$id" --arg file "$file" --arg reason "$reason" \
		'{event:"verify_failed", id:$id, file:$file, reason:$reason}'
}

ledger_round_start() {
	local round="$1"
	_ledger_event --argjson round "$round" '{event:"round_start", round:$round}'
}

# Records a review-round.sh timeout outcome. outcome is "recovered" (the free
# retry succeeded, exit 20) or "exhausted" (both attempts timed out, exit 21).
# Logged in addition to ledger_round_start on "recovered"; logged alone (no
# round_start) on "exhausted", since an exhausted round is not counted.
ledger_round_timeout() {
	local round="$1" outcome="$2"
	_ledger_event --argjson round "$round" --arg outcome "$outcome" \
		'{event:"round_timeout", round:$round, outcome:$outcome}'
}

# Records the raw intent-verifier verdict as soon as it returns, before any
# decision is made about it. Exists as a separate event from intent_verified
# so ledger_intent_verified's guard has something to check independently of
# the terminal call itself.
ledger_verifier_result() {
	local id="$1" intent_met="$2" rationale="$3"
	_ledger_event --arg id "$id" --argjson met "$intent_met" --arg rat "$rationale" \
		'{event:"verifier_result", id:$id, intent_met:$met, rationale:$rat}'
}

# Records the surgeon's "Already resolved:" outcome -- a sanctioned bypass of
# preflight and the verifier (Phase 5). Checked by ledger_intent_verified's
# guard as an alternative to a passing verifier_result.
ledger_already_resolved() {
	local id="$1"
	_ledger_event --arg id "$id" '{event:"already_resolved", id:$id}'
}

# True if this id's most recent decision event recorded requires_verify:true.
_ledger_requires_verify() {
	local id="$1"
	[ -f "$LEDGER" ] || return 1
	local req
	req=$(jq -rs --arg id "$id" \
		'[.[] | select(.event=="decision" and .id==$id)] | last | .requires_verify // false' \
		"$LEDGER" 2>/dev/null) || return 0 # jq error: assume verification required (fail safe)
	[ "$req" = "true" ]
}

# True if this id already has an already_resolved event, or a verifier_result
# event with intent_met:true.
_ledger_verification_satisfied() {
	local id="$1"
	[ -f "$LEDGER" ] || return 1
	local ok
	ok=$(jq -rs --arg id "$id" '
		any(.[]; .event=="already_resolved" and .id==$id)
			or any(.[]; .event=="verifier_result" and .id==$id and .intent_met==true)
		' "$LEDGER" 2>/dev/null)
	[ "$ok" = "true" ]
}

# verified: intermediate event (tests passed, pending intent check).
# intent_verified: terminal event (tests passed AND intent confirmed).
# Note: ledger files written before the intent-verification change used verified as terminal;
# those are not replayable via ledger_handled_ids without special-casing pre-change runs.
#
# Guarded: refuses (stderr message, return 1, no event written) if this id's
# decision required verification (requires_verify:true) but neither an
# already_resolved event nor a passing verifier_result exists yet. This is
# the sequencing bug caught in the CLI-1 session made structurally
# unrepresentable: logging intent_verified out of order now fails loudly
# instead of silently succeeding.
ledger_intent_verified() {
	local id="$1"
	if _ledger_requires_verify "$id" && ! _ledger_verification_satisfied "$id"; then
		printf 'ledger_intent_verified: refusing "%s" -- requires_verify is true but no already_resolved or passing verifier_result event exists yet\n' "$id" >&2
		return 1
	fi
	_ledger_event --arg id "$id" '{event:"intent_verified", id:$id}'
}

ledger_intent_failed() {
	local id="$1" file="$2" reason="$3"
	_ledger_event --arg id "$id" --arg file "$file" --arg reason "$reason" \
		'{event:"intent_failed", id:$id, file:$file, reason:$reason}'
}

# Print all IDs that already have a terminal event (intent_verified or skip) across all ledgers for this PR.
# Usage: ledger_handled_ids <pr_number>
# Prints one ID per line.
# Line-tolerant: -R + fromjson? parses each line independently, so one corrupt
# or truncated ledger file cannot poison the concatenated stream and silently
# disable idempotency for every PR. Multi-line (pretty-printed) events are
# dropped by line parsing, but every event this function selects is written
# compact by _ledger_event; only pre-fix review_started events were multi-line
# and those carry no id.
ledger_handled_ids() {
	local pr="$1"
	local pattern="PR-${pr}-"
	local legacy_dir="${HOME}/.claude/anaiis-coderabbit/runs"
	local -a dirs=()
	[ -d "$LEDGER_DIR" ] && dirs+=("$LEDGER_DIR")
	[ -d "$legacy_dir" ] && dirs+=("$legacy_dir")
	[ ${#dirs[@]} -eq 0 ] && return 0
	find "${dirs[@]}" -name "*.jsonl" -exec sh -c \
		'for file do cat "$file"; printf "\n"; done' sh {} + 2>/dev/null \
		| jq -rR --arg pat "$pattern" \
			'fromjson? // empty
			| select((.event == "intent_verified" or .event == "skip") and (.id | startswith($pat))) | .id' 2>/dev/null \
		| sort -u
}
