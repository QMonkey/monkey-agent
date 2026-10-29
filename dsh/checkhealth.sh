#!/usr/bin/env bash
# shellcheck shell=bash
# dsh/checkhealth.sh — the DeepSeek Harness agent health hook. Sourced by
# checkhealth.sh via run_agent_hook: defines checkhealth_agent_dsh() and
# NOTHING ELSE executes at source time (no top-level commands — only
# function definitions).
#
# Failure policy: warn for recoverable problems, non-zero return only for
# real failures (node too old / binary missing / version unparsable / web
# profile not starting — the hook wrapper collects them); never exits,
# never prints a secret VALUE.
# ─────────────────────────────────────────────────────────────────────
# _dsh_web_smoke — prove the web profile actually boots: start it, give it
# 30s, then look for the :3080 startup banner in its log (the regex refuses
# a :30801-style false match).
#   - Port pre-check via lsof (provisioned on demand): a listener on :3080 —
#     any interface — means the web profile (or something else) is already
#     up; the smoke has nothing to prove, and its own bind would fail into
#     a false "no banner" report.
#   - Shutdown: exactly two kills — SIGTERM, a fixed 5s grace sleep, then
#     SIGKILL (a no-op against an already-dead process); wait reaps.
# Failure: no banner within 30s → warn + return 1 (the hook wrapper
# collects it).
_dsh_web_smoke() {
	have_native_cmd lsof || install_pkg lsof || true
	if have_native_cmd lsof && lsof -nP -iTCP:3080 -sTCP:LISTEN >/dev/null 2>&1; then
		ok "web profile smoke: something already listens on :3080 — the web profile is already running."
		return 0
	fi
	local log pid found=""
	log=$(mktemp "${TMPDIR:-/tmp}/dsh-web-smoke.XXXXXX") || {
		warn "web profile smoke skipped (mktemp failed)."
		return 1
	}
	dsh web --no-open >"$log" 2>&1 &
	pid=$!
	sleep 30
	if grep -qE ':3080([^0-9]|$)' "$log" 2>/dev/null; then
		found=1
	fi
	# || true on both kills: the target may have died during the 30s wait (the
	# exact smoke-failure case) and bash has already reaped it — kill then
	# returns 1, and under set -e that must not abort the function (the
	# banner warn + log cleanup below still need to run). Success checking
	# is pointless: a failed kill can only mean "already dead", which is
	# the desired state.
	kill "$pid" 2>/dev/null || true
	sleep 5
	kill -9 "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	rm -f "$log"
	if [ -n "$found" ]; then
		ok "web profile smoke: server started on port 3080 and was stopped."
		return 0
	fi
	warn "web profile smoke: no startup banner within 30s — run 'dsh web --no-open' by hand to see the error."
	return 1
}

# checkhealth_agent_dsh — the agent contract function (see lib/agent.sh).
checkhealth_agent_dsh() {
	local rc=0

	# Node.js 22+ floor.
	if have_native_cmd node; then
		ok "node version: $(node -v 2>/dev/null)"
		if ! bin_at_least node 22; then
			warn "node is older than 22 — dsh requires Node.js 22+; upgrade it: $(get_install_hint node)"
			rc=1
		fi
	else
		warn "node not found — dsh requires Node.js 22+: $(get_install_hint node)"
		rc=1
	fi

	# Binary + version.
	if have_native_cmd dsh; then
		local ver
		ver=$(extract_version dsh '[0-9]+\.[0-9]+\.[0-9]+[^ ]*')
		if [ -n "$ver" ]; then
			ok "dsh version: $ver"
		else
			warn "dsh found but --version produced no parsable output."
			rc=1
		fi
		# Web profile smoke (skipped above when the binary is missing —
		#    that failure is already reported).
		_dsh_web_smoke || rc=$?
	else
		warn "dsh binary not found — install it: npm install -g @deepseek-ai/dsh"
		rc=1
	fi

	llm_health dsh DSH_LLM_API_KEY DSH_LLM_BASE_URL DSH_LLM_MODEL "" ""

	return "$rc"
}
