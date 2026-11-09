#!/usr/bin/env bash
# shellcheck shell=bash
# dsh/install.sh — the DeepSeek Harness agent hook, sourced through
# run_agent_hook: defines install_agent_dsh() and nothing else runs at
# source time.
#
# Facts this file depends on:
#   - npm @deepseek-ai/dsh (bin `dsh`), Node.js 22+. `dsh plugin` forwards
#     to pnpm, so pnpm is provisioned before any plugin install.
#   - Web profile only (headless/GUI/TUI are out of scope); config at
#     ~/.dsh/profiles/web/cordis.patch.yml, one Cordis patch entry per plugin
#     row, re-read on every request (config edits need no restart).
#   - apiKeyEnv is the credential indirection: the key VALUE never enters the
#     file — dsh resolves it from the process environment per request.
#   - Renderer is gomplate over {{ .Env.NAME }}; values reach it through the
#     environment only (never argv) and are scalar-safe (URLs, model ids,
#     numbers).
#   - Base URL / model id default to the OFFICIAL public endpoint (public
#     information); a private endpoint or model id is a secret and comes from
#     DSH_LLM_BASE_URL / DSH_LLM_MODEL or the shared LLM_* layer.
_dsh_install_binary() {
	npm_agent_install dsh @deepseek-ai/dsh 22 "npm install -g @deepseek-ai/dsh"
}

# _dsh_install_plugins — install the web profile's plugins from
# dsh/plugins.txt. `dsh plugin --profile web add <id>` forwards to pnpm in
# the profile directory (dsh requires a pnpm on PATH for plugin management;
# provisioned via npm when missing), an already-installed plugin (found by
# `dsh plugin --profile web ls`) is skipped, and pnpm's own re-add is a no-op
# success, so the step is idempotent. Per-plugin failures are warned and
# collected; the step returns non-zero only if pnpm or any plugin failed.
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

	# Render the config. The API key renders as a NAME only (apiKeyEnv
	#    indirection); base URL and model are VALUES, public information by
	#    default (DeepSeek's official endpoint/model) and machine-local
	#    otherwise. The model catalog rows drive both the YAML list and the
	#    reasoningEfforts map: labels map to themselves (the wire value equals
	#    the label), undeclared levels stay unavailable, and models.dev's
	#    "none" tier renders under dsh's level id "off" whose wire value is the
	#    endpoint's own disable label.
	local template="$AGENT_REPO_ROOT/dsh/cordis.patch.yml.template"
	local rendered="$AGENT_HOME/dsh/cordis.patch.yml"
	llm_resolve DSH
	# The subshell is not for `|| rc=$?` (identical either way): it bounds these
	# exports, so nothing resolved here survives into another agent's render, or
	# into secret()'s process-env fallback. Keep the parentheses.
	(
		# Only resolved VALUES are exported. Every reference the template
		# reads must be exported, empty included — gomplate aborts the render
		# on an unset one and reports the offending names.
		export DSH_LLM_BASE_URL="$EFF_BASE" DSH_LLM_API_KEY_ENV_NAME="$EFF_KEY_NAME" DSH_LLM_MODEL_ROWS="$EFF_ROWS"
		render "$template" "$rendered"
	) || rc=$?

	# Link the rendered file into dsh's web-profile location (creates
	#    ~/.dsh/profiles/web if needed; link_config's takeover mode moves a
	#    foreign regular file there to <dst>.link-bak first — this repo owns
	#    the web profile's cordis.patch.yml).
	mkdir -p "$HOME/.dsh/profiles/web"
	link_config "$rendered" "$HOME/.dsh/profiles/web/cordis.patch.yml" takeover || rc=$?

	return "$rc"
}
