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

ledger_decision() {
	local id="$1" severity="$2" decision="$3" rationale="$4"
	_ledger_event --arg id "$id" --argjson sev "$severity" --arg dec "$decision" --arg rat "$rationale" \
		'{event:"decision", id:$id, severity:$sev, decision:$dec, rationale:$rat}'
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

# Print all IDs that already have a terminal event (verified or skip) across all ledgers for this PR.
# Usage: ledger_handled_ids <pr_number>
# Prints one ID per line.
ledger_handled_ids() {
	local pr="$1"
	local pattern="PR-${pr}-"
	[ -d "$LEDGER_DIR" ] || return 0
	find "$LEDGER_DIR" -name "*.jsonl" -exec cat {} + 2>/dev/null \
		| jq -r --arg pat "$pattern" \
			'select((.event == "verified" or .event == "skip") and (.id | startswith($pat))) | .id' 2>/dev/null \
		| sort -u
}
