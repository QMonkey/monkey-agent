#!/usr/bin/env bash
# shellcheck shell=bash
# opencode/install.sh — the OpenCode agent hook, sourced through
# run_agent_hook: defines install_agent_opencode() and nothing else runs at
# source time. Install does four things: registers this agent's override
# vars (via the shared write_secrets_template call), ensures the binary,
# renders opencode.json.template → ~/.config/agent/opencode/opencode.json,
# and links it to ~/.config/opencode/opencode.json.
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
#     lane as every other agent, so one upgrade path serves all. The official
#     script (https://opencode.ai/install) is the fallback for hosts without
#     node/npm: verified fully non-interactive, but it installs to
#     ~/.opencode/bin and appends PATH lines to shell rc files — so this hook
#     keeps its own success probe instead of npm_agent_install's PATH hint.
#   - No Node floor is asserted here: opencode-ai ships its own runtime, and
#     npm_install_g self-heals node/npm via ensure_node_and_npm.
_opencode_install_fallback() {
	info "npm lane failed — falling back to the official install script (https://opencode.ai/install)..."
	retry -s "opencode installer" sh -c 'curl -fsSL https://opencode.ai/install | bash'
}

# install_agent_opencode — the agent contract function (see lib/agent.sh).
# Failure policy: warns for recoverable problems, returns non-zero on real
# failures (the hook wrapper collects them); never exits, never blocks on a
# missing secret — an unset LLM_* renders as an empty string in the config
# and health flags it later.
install_agent_opencode() {
	local rc=0
	mkdir -p "$AGENT_HOME"

	# Binary: npm lane first, official script as fallback (see header).
	if have_native_cmd opencode; then
		ok "opencode already installed."
	else
		if ! npm_install_g opencode-ai; then
			_opencode_install_fallback || rc=$?
		fi
		if [ "$rc" -ne 0 ]; then
			warn "opencode installation failed (rc $rc) — install it manually: npm i -g opencode-ai (or curl -fsSL https://opencode.ai/install | bash)"
			return 1
		fi
		# Success probe: on this shell's PATH. The npm lane exports its prefix
		# bin in-process; the curl lane edits rc files for NEW shells and drops
		# the binary in ~/.opencode/bin — the install itself succeeded, so that
		# degrades to a hint, not a failure.
		if ! have_native_cmd opencode; then
			if [ -x "$HOME/.opencode/bin/opencode" ]; then
				warn "opencode installed to $HOME/.opencode/bin but not on this shell's PATH — open a new shell."
			else
				warn "opencode installation did not produce a usable binary — install it manually: npm i -g opencode-ai (or curl -fsSL https://opencode.ai/install | bash)"
				return 1
			fi
		fi
	fi

	# Render the config. render resolves references only — it cannot apply the
	#    per-field override precedence itself, so the effective values are
	#    resolved here via llm_resolve (the real agent.env stays untouched).
	#    The model catalog rows carry the reasoning flag and the options block,
	#    which appears only when the model declares a safe tier (an effort sent
	#    to a model that does not declare one risks a gateway 400).
	local template="$AGENT_REPO_ROOT/opencode/opencode.json.template"
	local rendered="$AGENT_HOME/opencode/opencode.json"
	llm_resolve OPENCODE
	# The subshell is not for `|| rc=$?` (identical either way): it bounds these
	# exports, so nothing resolved here survives into another agent's render, or
	# into secret()'s process-env fallback. Keep the parentheses.
	(
		# Only resolved VALUES are exported. Every reference the template
		# reads must be exported, empty included — gomplate aborts the render
		# on an unset one and reports the offending names.
		export OPENCODE_LLM_BASE_URL="$EFF_BASE" OPENCODE_LLM_MODEL="$EFF_MODEL" \
			OPENCODE_LLM_API_KEY_ENV_NAME="$EFF_KEY_NAME" OPENCODE_LLM_MODEL_ROWS="$EFF_ROWS"
		render "$template" "$rendered"
	) || rc=$?

	# Link the rendered file into OpenCode's config location (creates
	#    ~/.config/opencode if needed; link_config's takeover mode moves a
	#    foreign regular file there to <dst>.link-bak first — this repo owns
	#    opencode.json).
	mkdir -p "$HOME/.config/opencode"
	link_config "$rendered" "$HOME/.config/opencode/opencode.json" takeover || rc=$?

	return "$rc"
}
