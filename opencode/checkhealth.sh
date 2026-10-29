#!/usr/bin/env bash
# shellcheck shell=bash
# opencode/checkhealth.sh — the OpenCode agent health hook. Sourced by
# checkhealth.sh via run_agent_hook: defines checkhealth_agent_opencode() and
# NOTHING ELSE executes at source time (no top-level commands — only
# function definitions).
#
# Checks, in order:
#   1. binary + version   (`opencode --version`)
#   2. secrets presence   (LLM_API_KEY non-empty → WARN if empty, per the
#      brief; base URL / model resolved through the OPENCODE_LLM_* override
#      layer, WARN if empty)
#   3. connectivity       (GET {baseURL}/models with an Authorization
#      header, ~10s timeout; a failure is recorded via
#      record_agent_failure and counts toward checkhealth's exit code,
#      but the hook itself still returns 0 for it)
#
# Connectivity skip switch: export SKIP_CONNECTIVITY=1 (advisory downgrade
# for offline machines — design §4.6). Picked over a CLI flag because agent
# hooks receive no arguments from the entry points.
#
# Failure policy: warn for recoverable problems, non-zero return only for
# real failures (binary missing / version unparsable — the hook wrapper
# collects it); never exits, never prints a secret VALUE.

# checkhealth_agent_opencode — the agent contract function (see lib/agent.sh).
checkhealth_agent_opencode() {
	local rc=0

	# Binary + version.
	if have_native_cmd opencode; then
		local ver
		ver=$(extract_version opencode '[0-9]+\.[0-9]+\.[0-9]+[^ ]*')
		if [ -n "$ver" ]; then
			ok "opencode version: $ver"
		else
			warn "opencode found but --version produced no parsable output."
			rc=1
		fi
	else
		warn "opencode binary not found — install it: npm i -g opencode-ai (or curl -fsSL https://opencode.ai/install | bash)"
		rc=1
	fi

	llm_health opencode OPENCODE_LLM_API_KEY OPENCODE_LLM_BASE_URL OPENCODE_LLM_MODEL "" " The rendered opencode.json will then have empty fields."

	return "$rc"
}
