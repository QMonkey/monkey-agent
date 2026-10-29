#!/usr/bin/env bash
# shellcheck shell=bash
# dsh/install.sh — the DeepSeek Harness agent hook. Sourced by the entry
# points via run_agent_hook: defines install_agent_dsh() and NOTHING ELSE
# executes at source time (no top-level commands — only function
# definitions).
#
# Research (pinned 2026-10-24):
#   - Package: npm @deepseek-ai/dsh (verified npm name; bin: `dsh`) — the
#     docs' `npm install -g @deepseek-ai/dsh` is the same package with the
#     `dsh` bin. Node.js 22+ required.
#   - Plugin management (`dsh plugin`) forwards to pnpm — pnpm is
#     provisioned automatically before any plugin install.
#   - Web profile only (headless/GUI/TUI out of scope — design §4.4).
#   - Config: ~/.dsh/profiles/web/cordis.patch.yml (YAML, comments legal).
#
# _dsh_install_binary — make sure `dsh` exists: Node.js 22+ and npm via the
# framework package manager when missing, then the pinned npm global
# install. Idempotent: a present binary short-circuits. Returns non-zero on
# a real failure (caller's hook wrapper collects it).
_dsh_install_binary() {
	if have_native_cmd dsh; then
		ok "dsh already installed."
		return 0
	fi
	local rc=0
	# Node.js 22+ floor: ensure_node_at_least provisions node meeting the
	# floor (distro packages when new enough, Homebrew when the distro
	# index ships 18/20 — see toolchain.sh).
	ensure_node_at_least 22 || {
		warn "Node.js 22+ is required but not available (found: $(node -v 2>/dev/null || echo none)) — install Node.js 22+ manually: $(get_install_hint node)"
		return 1
	}
	if ! bin_at_least node 22; then
		warn "Node.js 22+ is required but not available (found: $(node -v 2>/dev/null || echo none)) — install Node.js 22+ manually: $(get_install_hint node)"
		return 1
	fi
	info "Installing dsh (npm_install_g @deepseek-ai/dsh — pinned 2026-10-24, https://github.com/deepseek-ai/deepseek-harness)..."
	# npm_install_g (framework toolchain): ensure_node_and_npm, user-owned prefix,
	# retry, npm ≥ 11.19 --allow-scripts gate. dsh declares no lifecycle
	# scripts today, so the gate is a no-op here — the helper is used for
	# the prefix/retry semantics and lane consistency with the other agents.
	npm_install_g @deepseek-ai/dsh || rc=$?
	if [ "$rc" -ne 0 ]; then
		warn "dsh installation failed (rc $rc) — install it manually: npm install -g @deepseek-ai/dsh"
		return 1
	fi
	if have_native_cmd dsh; then
		return 0
	fi
	# npm succeeded, so the bin exists in npm's global prefix — just not on
	# THIS shell's PATH yet (a new shell picks it up).
	warn "dsh installed but not on this shell's PATH — open a new shell (npm's global bin directory)."
	return 0
}

# _dsh_install_plugins — install the web profile's 4 plugins from
# dsh/plugins.txt. `dsh plugin --profile web add <id>` forwards to pnpm in
# the profile directory (dsh requires a pnpm on PATH for plugin management —
# verified 2026-10-24; provisioned via npm when missing), an
# already-installed plugin (found by `dsh plugin --profile web ls`) is
# skipped, and pnpm's own re-add is a no-op success, so the step is
# idempotent. Per-plugin failures are warned and collected; the step
# returns non-zero only if pnpm or any plugin failed.
_dsh_install_plugins() {
	if ! have_native_cmd dsh; then
		warn "dsh binary not found — skipping web-profile plugin install."
		return 1
	fi
	local rc=0 id installed added=""
	if [ ! -f "$AGENT_REPO_ROOT/dsh/plugins.txt" ]; then
		warn "dsh/plugins.txt not found in this checkout — skipping web-profile plugin install."
		return 1
	fi
	if ! have_native_cmd pnpm; then
		info "pnpm not found — dsh plugin management needs it; installing via npm..."
		npm_install_g pnpm || rc=$?
		if [ "$rc" -ne 0 ] || ! have_native_cmd pnpm; then
			warn "pnpm install failed — dsh cannot manage plugins without it; install pnpm manually: npm install -g pnpm"
			return 1
		fi
		rc=0
	fi
	installed=$(dsh plugin --profile web ls 2>/dev/null) || installed=""
	while IFS= read -r id; do
		case "$id" in
		'' | \#*) continue ;;
		esac
		case "$installed" in
		*"$id"*)
			ok "plugin $id already installed (web profile)."
			continue
			;;
		esac
		# < /dev/null: dsh plugin (a pnpm forward) must not consume the
		# plugins.txt lines this while-read loop is reading.
		if dsh plugin --profile web add "$id" </dev/null; then
			ok "plugin $id installed (web profile)."
			added=1
		else
			warn "plugin $id install failed — add it manually: dsh plugin --profile web add $id"
			rc=1
		fi
	done <"$AGENT_REPO_ROOT/dsh/plugins.txt"
	# Bundle membership only changes on the next profile start (the plugin
	# manager's own rule) — one hint per run when something was installed.
	if [ -n "$added" ]; then
		info "Plugin bundles activate on the next 'dsh web' start — restart the web profile if it is running."
	fi
	return "$rc"
}
# install_agent_dsh — the agent contract function (see lib/agent.sh).
# Failure policy: warns for recoverable problems, returns non-zero on real
# failures (the hook wrapper collects them); never exits, never blocks on a
# missing secret — unset values render as documented fallbacks and health
# flags them later.
install_agent_dsh() {
	local rc=0
	mkdir -p "$AGENT_HOME"

	# Binary (Node.js 22+ and npm via the package manager when missing).
	_dsh_install_binary || rc=$?

	# Web-profile plugins (dsh/plugins.txt; needs the binary).
	_dsh_install_plugins || rc=$?

	# Render the config. render is a pure envsubst engine — it cannot
	#    apply the §4.2 per-field override precedence itself, so the
	#    effective values are resolved here and exported; the real
	#    secrets.env stays untouched.
	#    The API key renders as a NAME only (apiKeyEnv indirection); base
	#    URL and model are VALUES, but public information by default
	#    (DeepSeek's official endpoint/model) and machine-local otherwise.
	local eff_key_var="LLM_API_KEY"
	if [ -n "$(secret DSH_LLM_API_KEY 2>/dev/null)" ]; then
		eff_key_var="DSH_LLM_API_KEY"
	fi
	local eff_base eff_model
	eff_base=$(secret DSH_LLM_BASE_URL LLM_BASE_URL 2>/dev/null)
	eff_model=$(secret DSH_LLM_MODEL LLM_MODEL 2>/dev/null)
	if [ -z "$(secret DSH_LLM_API_KEY 2>/dev/null)" ] &&
		[ -z "$(secret LLM_API_KEY 2>/dev/null)" ]; then
		info "LLM_API_KEY / DSH_LLM_API_KEY not set — the config references an empty variable; fill ${SECRETS_FILE#"$HOME"/} and re-run (or set it in the shell)."
	fi

	local template="$AGENT_REPO_ROOT/dsh/cordis.patch.yml.template"
	local rendered="$AGENT_HOME/dsh/cordis.patch.yml"
	(
		# The RESOLVED override-layer values are exported here.
		export DSH_API_KEY_ENV="$eff_key_var" \
			DSH_LLM_BASE_URL="$eff_base" \
			DSH_LLM_MODEL="$eff_model"
		render "$template" "$rendered"
	) || rc=$?

	# Link the rendered file into dsh's web-profile location (creates
	#    ~/.dsh/profiles/web if needed; a foreign regular file already
	#    there is backed up to <dst>.pre-agent.bak — this repo owns the
	#    web profile's cordis.patch.yml).
	mkdir -p "$HOME/.dsh/profiles/web"
	link_config "$rendered" "$HOME/.dsh/profiles/web/cordis.patch.yml" takeover || rc=$?

	return "$rc"
}
