#!/usr/bin/env bash
# Shared ledger helpers for anaiis-coderabbit.
# Source this file; do not execute directly.
# All functions write to $LEDGER (must be set by caller).

LEDGER_DIR="${HOME}/.claude/anaiis-coderabbit/runs"

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
	jq -n --arg branch "$branch" --arg base "$base" --arg mode "$mode" --arg ts "$iso" \
		'{event:"review_started", branch:$branch, base:$base, mode:$mode, ts:$ts}' >>"$LEDGER"
	export LEDGER
}

ledger_append() {
	printf '%s\n' "$1" >>"$LEDGER"
}

_ledger_event() {
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
		"$LEDGER" 2>/dev/null)
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
ledger_handled_ids() {
	local pr="$1"
	local pattern="PR-${pr}-"
	[ -d "$LEDGER_DIR" ] || return 0
	find "$LEDGER_DIR" -name "*.jsonl" -exec cat {} + 2>/dev/null \
		| jq -r --arg pat "$pattern" \
			'select((.event == "intent_verified" or .event == "skip") and (.id | startswith($pat))) | .id' 2>/dev/null \
		| sort -u
}
