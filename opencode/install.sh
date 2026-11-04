#!/usr/bin/env bash
# shellcheck shell=bash
# opencode/install.sh — the OpenCode agent hook, sourced through
# run_agent_hook: defines install_agent_opencode() and nothing else runs at
# source time. Install does four things: registers this agent's override
# vars (via the shared write_secrets_template call), ensures the binary,
# renders opencode.json.template → ~/.config/agent/opencode.json, and links
# it to ~/.config/opencode/opencode.json.
#
# Pitfalls this file encodes:
#   - The API key is NEVER rendered as a value: the config carries OpenCode's
#     native {env:VAR} form, and the NAME is resolved at render time
#     (OPENCODE_LLM_API_KEY when set, else the shared LLM_API_KEY). Template
#     references: OPENCODE_LLM_BASE_URL / _MODEL (values) and
#     OPENCODE_LLM_API_KEY_ENV_NAME (a NAME) — via the environment only.
#   - The tmux-scout plugin is NOT registered here: the tmux setup owns both
#     the plugin file and its OpenCode-side registration (at tmux startup).
#   - Primary install lane is npm (`npm install -g opencode-ai`) — the same
#     lane as every other agent, so one upgrade path serves all. The
#     official script (https://opencode.ai/install) is the fallback for hosts
#     without node/npm; verified fully non-interactive, but note it installs
# _opencode_install_binary — make sure the opencode binary exists, using the
# pinned official method. Idempotent: a present binary short-circuits.
# Returns non-zero on a real failure (caller's hook wrapper collects it).

#     to ~/.opencode/bin and appends PATH lines to shell rc files.
_opencode_install_binary() {
	if have_native_cmd opencode; then
		ok "opencode already installed."
		return 0
	fi
	local rc=0
	# npm_install_g (framework toolchain) self-heals npm/node via ensure_node_and_npm —
	# no pre-check needed. PRIMARY lane: same npm lane as the other agents,
	# one upgrade path; opencode-ai ships a postinstall script that the
	# --allow-scripts gate (npm ≥ 11.19) must unblock.
	# FALLBACK: the official script, when the npm lane fails. curl absence is
	# caught by pipefail (rc 127) and the manual hint below — the one-liner
	# entry required curl anyway, and local checkouts just take this path.
	if ! npm_install_g opencode-ai; then
		info "npm lane failed — falling back to the official install script (https://opencode.ai/install)..."
		retry -s "opencode installer" sh -c 'curl -fsSL https://opencode.ai/install | bash' || rc=$?
	fi
	if [ "$rc" -ne 0 ]; then
		warn "opencode installation failed (rc $rc) — install it manually: npm i -g opencode-ai (or curl -fsSL https://opencode.ai/install | bash)"
		return 1
	fi
	# Success probe: on this shell's PATH. npm lane — npm_install_g exports
	# the prefix bin in-process; curl lane edits rc files for NEW shells.
	if have_native_cmd opencode; then
		return 0
	fi
	# The curl-script fallback drops the binary in ~/.opencode/bin — on the
	# PATH of NEW shells (it edited the rc files) but possibly not this one.
	# The install itself succeeded: degrade to a hint, not a failure.
	if [ -x "$HOME/.opencode/bin/opencode" ]; then
		warn "opencode installed to $HOME/.opencode/bin but not on this shell's PATH — open a new shell."
		return 0
	fi
	warn "opencode installation did not produce a usable binary — install it manually: npm i -g opencode-ai (or curl -fsSL https://opencode.ai/install | bash)"
	return 1
}

# install_agent_opencode — the agent contract function (see lib/agent.sh).
# Failure policy: warns for recoverable problems, returns non-zero on real
# failures (the hook wrapper collects them); never exits, never blocks on a
# missing secret — an unset LLM_* renders as an empty string in the config
# and health flags it later.
install_agent_opencode() {
	local rc=0
	mkdir -p "$AGENT_HOME"

	# Binary (official method, pinned — see header comment).
	_opencode_install_binary || rc=$?

	# Render the config. render resolves references only — it cannot
	#    apply the §4.2 per-field override precedence itself, so the
	#    effective values are resolved here via secret() and exported;
	#    __LLM_BASE_URL__/__LLM_MODEL__ then resolve to the override, and
	#    the real secrets.env stays untouched.
	local template="$AGENT_REPO_ROOT/opencode/opencode.json.template"
	local rendered="$AGENT_HOME/opencode/opencode.json"
	# The key renders as an {env:NAME} reference — resolve WHICH name (the
	# OPENCODE_LLM_API_KEY override, or the shared LLM_API_KEY).
	local eff_key_name="LLM_API_KEY"
	if [ -n "$(secret OPENCODE_LLM_API_KEY 2>/dev/null)" ]; then
		eff_key_name="OPENCODE_LLM_API_KEY"
	fi
	local eff_base eff_model
	eff_base=$(secret OPENCODE_LLM_BASE_URL LLM_BASE_URL 2>/dev/null)
	eff_model=$(secret OPENCODE_LLM_MODEL LLM_MODEL 2>/dev/null)
	if [ -z "$(secret OPENCODE_LLM_API_KEY 2>/dev/null)" ] && [ -z "$(secret LLM_API_KEY 2>/dev/null)" ]; then
		info "LLM_API_KEY / OPENCODE_LLM_API_KEY not set — the config references an empty variable; fill ${SECRETS_FILE#"$HOME"/} and re-run."
	fi
	# Model catalog: one "id|context|output|efforts|pick" row per model
	# (llm_model_rows) — the template renders the models map from it, including
	# the reasoning flag and the options block, which appears only when the
	# model declares a safe tier (an effort sent to a model that does not
	# declare one risks a gateway 400).
	local model_rows
	model_rows=$(llm_model_rows "$eff_model")
	# The subshell is not for `|| rc=$?` (identical either way): it bounds these
	# exports, so nothing resolved here survives into another agent's render, or
	# into secret()'s process-env fallback. Keep the parentheses.
	(
		# Only resolved VALUES are exported. Every reference the template
		# reads must be exported, empty included — gomplate aborts the render
		# on an unset one and reports the offending names.
		export OPENCODE_LLM_BASE_URL="$eff_base" OPENCODE_LLM_MODEL="$eff_model" \
			OPENCODE_LLM_API_KEY_ENV_NAME="$eff_key_name" OPENCODE_LLM_MODEL_ROWS="$model_rows"
		render "$template" "$rendered"
	) || rc=$?

	# Link the rendered file into OpenCode's config location (creates
	#    ~/.config/opencode if needed; a foreign regular file already there
	#    is backed up to <dst>.pre-agent.bak — this repo owns opencode.json).
	mkdir -p "$HOME/.config/opencode"
	link_config "$rendered" "$HOME/.config/opencode/opencode.json" takeover || rc=$?

	return "$rc"
}
