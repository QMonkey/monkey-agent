#!/usr/bin/env bash
# shellcheck shell=bash
# dsh/checkhealth.sh — the DeepSeek Harness agent health hook. Sourced by
# checkhealth.sh via run_agent_hook: defines checkhealth_agent_dsh() and
# NOTHING ELSE executes at source time (no top-level commands — only
# function definitions).
#
# Failure policy: warn for recoverable problems, non-zero return only for
# real failures (node too old / a binary missing / version unparsable / the
# web profile not starting / a profile that does not compose / the shared
# rules file not resolving — the hook wrapper collects them); never exits,
# never prints a secret VALUE.
# ─────────────────────────────────────────────────────────────────────
# _dsh_rules_probe — the rules file both profiles share, a link into the
# checkout. Its two failures need different fixes: a dangling link means the
# checkout moved, a missing path means it was never published. dsh reads
# badFilePolicy=fail, so an unresolvable file breaks the mount — probed here
# rather than waiting for someone to boot a profile and prompt on every call.
_dsh_rules_probe() {
	local rules="$AGENT_HOME/dsh/rules.yaml"
	if [ -f "$rules" ]; then
		ok "permission rules resolve: $rules."
		return 0
	fi
	if [ -L "$rules" ]; then
		warn "the rules link is dangling: $rules -> $(readlink "$rules") does not resolve — the checkout moved; dsh reads badFilePolicy=fail."
	else
		warn "the rules file was never published: $rules — re-run the installer (the dsh hook links dsh/rules.yaml out of the checkout)."
	fi
	return 1
}

# _dsh_profile_probe <profile> — prove the profile exists and composes without
# booting it (`dsh --profile <profile> --dump-config` composes the layers and
# exits; the TUI would additionally need a tty). We do NOT assert that the
# composed permission-rules row still names our rules file: matching it meant
# anchoring on indentation in dsh's output, which breaks on formatting drift.
# `dsh-tui doctor` is no gate either — it exits 0 even when an item fails.
_dsh_profile_probe() {
	local profile="$1" out
	if ! out=$(dsh --profile "$profile" --dump-config 2>&1); then
		warn "$profile profile does not compose — install it: ./install.sh --with-dsh (manifests: dsh/plugins.txt, dsh/plugins-tui.txt). First line: $(printf '%s\n' "$out" | head -n1)"
		return 1
	fi
	ok "$profile profile composes."
	return 0
}

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

	node_floor_check dsh 22.19 || rc=1

	# Both binaries + versions. The profile probes run only when the dsh
	# launcher is actually there (a missing one is already reported; starting
	# a server to probe it would just add a second symptom).
	if binary_version_check dsh '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' "npm install -g @deepseek-ai/dsh"; then
		_dsh_web_smoke || rc=$?
		_dsh_rules_probe || rc=$?
		_dsh_profile_probe web || rc=$?
		_dsh_profile_probe dsh-tui || rc=$?
	else
		rc=1
	fi
	# The TUI launcher is its own failure: `dsh --profile dsh-tui` runs the
	# profile without it, so a missing launcher is not a broken profile.
	if ! binary_version_check dsh-tui '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' "npm install -g @deepseek-harness-tui/dsh-tui"; then
		rc=1
	fi

	llm_health dsh DSH_LLM_API_KEY DSH_LLM_BASE_URL DSH_LLM_MODEL "" "" "" \
		"$AGENT_HOME/dsh/cordis.patch.yml" yaml-ids

	return "$rc"
}
