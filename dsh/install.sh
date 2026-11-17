#!/usr/bin/env bash
# shellcheck shell=bash
# dsh/install.sh — the DeepSeek Harness agent hook, sourced through
# run_agent_hook: defines install_agent_dsh() and nothing else runs at
# source time.
#
# Facts this file depends on:
#   - npm @deepseek-ai/dsh (bin `dsh`) and @deepseek-harness-tui/dsh-tui (bin
#     `dsh-tui`), Node.js 22.19+ — the TUI's floor, above dsh's own 22. `dsh
#     plugin` forwards to pnpm, so pnpm is provisioned before any plugin step.
#   - Two profiles, both maintained here: `web` (a shipped dsh template) and
#     `dsh-tui` (a third-party surface — dsh ships no tui template, so the
#     profile exists only because its surface bundle is added).
#   - Config at ~/.dsh/profiles/<profile>/cordis.patch.yml, both symlinked to
#     the one rendered file and re-read on every request (config edits need
#     no restart). A patch row overrides by `id` and replaces that row's
#     config block whole, so the template restates every key that stays
#     active. The TUI keeps its own preferences in ~/.dsh-tui/settings.json,
#     importing that one row from the patch once — providers stay
#     patch-driven.
#   - Default authorization: dsh has no per-tool allow list, so the
#     pre-approved tool set is dsh/rules.yaml (linked, not rendered — it holds
#     no value) and the baseline is upstream's DSH_PERMISSION_MODE.
#   - apiKeyEnv is the credential indirection: the key VALUE never enters the
#     file — dsh resolves it from the process environment per request.
#   - Renderer is gomplate over {{ .Env.NAME }}; values reach it through the
#     environment only (never argv) and are scalar-safe (URLs, model ids,
#     numbers, an absolute path).
#   - Base URL / model id default to the OFFICIAL public endpoint (public
#     information); a private endpoint or model id is a secret and comes from
#     DSH_LLM_BASE_URL / DSH_LLM_MODEL or the shared LLM_* layer.
_dsh_install_binary() {
	npm_agent_install dsh @deepseek-ai/dsh 22.19 "npm install -g @deepseek-ai/dsh"
	# The TUI launcher. Its npm peers are all optional, so it never rewrites
	# the existing dsh install; engine alignment is `dsh-tui doctor`'s to
	# report, not ours to parse.
	npm_agent_install dsh-tui @deepseek-harness-tui/dsh-tui 22.19 "npm install -g @deepseek-harness-tui/dsh-tui"
}

# _dsh_install_plugins <profile> <manifest> — install one profile's plugins
# from dsh/<manifest> with `dsh plugin --profile <profile> add <id>`, a pnpm
# forward (pnpm is provisioned first; the have_native_cmd guard makes the
# second profile's call a plain lookup). Adding to a profile that does not
# exist creates it — how the dsh-tui profile comes to be. Installed ids are
# skipped and pnpm's re-add is a no-op, so the step is idempotent; per-plugin
# failures are warned and collected.
_dsh_install_plugins() {
	local profile="$1" manifest="$2"
	if ! have_native_cmd dsh; then
		warn "dsh binary not found — skipping $profile profile plugin install."
		return 1
	fi
	local rc=0 id installed added=""
	if [ ! -f "$AGENT_REPO_ROOT/dsh/$manifest" ]; then
		warn "dsh/$manifest not found in this checkout — skipping $profile profile plugin install."
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
	installed=$(dsh plugin --profile "$profile" ls 2>/dev/null) || installed=""
	while IFS= read -r id; do
		case "$id" in
		'' | \#*) continue ;;
		esac
		case "$installed" in
		*"$id"*)
			ok "plugin $id already installed ($profile profile)."
			continue
			;;
		esac
		# < /dev/null: dsh plugin (a pnpm forward) must not consume the
		# manifest lines this while-read loop is reading.
		if dsh plugin --profile "$profile" add "$id" </dev/null; then
			ok "plugin $id installed ($profile profile)."
			added=1
		else
			warn "plugin $id install failed — add it manually: dsh plugin --profile $profile add $id"
			rc=1
		fi
	done <"$AGENT_REPO_ROOT/dsh/$manifest"
	# Bundle membership only changes on the next profile start (the plugin
	# manager's own rule) — one hint per run when something was installed.
	if [ -n "$added" ]; then
		info "Plugin bundles activate on the next 'dsh $profile' start — restart the $profile profile if it is running."
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

	# Binary (Node.js 22.19+ and npm via the package manager when missing).
	_dsh_install_binary || rc=$?

	# Profile plugins (need the binary). Each manifest is one profile's list;
	# the dsh-tui one also creates the profile, dsh shipping no tui template.
	_dsh_install_plugins web plugins.txt || rc=$?
	_dsh_install_plugins dsh-tui plugins-tui.txt || rc=$?

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
	# The permission rules hold no machine-local value, so they are linked out
	# of the checkout instead of rendered. First, because the patch names this
	# path and permission-rules reads badFilePolicy=fail.
	local rules_file="$AGENT_HOME/dsh/rules.yaml"
	link_config "$AGENT_REPO_ROOT/dsh/rules.yaml" "$rules_file" takeover || rc=$?
	llm_resolve DSH
	# The subshell is not for `|| rc=$?` (identical either way): it bounds these
	# exports, so nothing resolved here survives into another agent's render, or
	# into secret()'s process-env fallback. Keep the parentheses.
	(
		# Only resolved VALUES are exported. Every reference the template
		# reads must be exported, empty included — gomplate aborts the render
		# on an unset one and reports the offending names. AGENT_HOME is here
		# because the rules path must land absolute: dsh resolves a relative
		# rulesFile against the session cwd and never expands ~.
		export DSH_LLM_BASE_URL="$EFF_BASE" DSH_LLM_API_KEY_ENV_NAME="$EFF_KEY_NAME" DSH_LLM_MODEL_ROWS="$EFF_ROWS"
		export AGENT_HOME
		render "$template" "$rendered"
	) || rc=$?

	# Link the rendered patch into both profile locations (creates the profile
	#    dirs if needed; link_config's takeover mode moves a foreign regular
	#    file there to <dst>.link-bak first — this repo owns both profiles'
	#    cordis.patch.yml). Guarded because takeover backs the current config
	#    up before it looks at the source: linking after a failed render would
	#    move a working config out of reach.
	local profile
	for profile in web dsh-tui; do
		if [ -f "$rendered" ]; then
			mkdir -p "$HOME/.dsh/profiles/$profile"
			link_config "$rendered" "$HOME/.dsh/profiles/$profile/cordis.patch.yml" takeover || rc=$?
		fi
	done

	return "$rc"
}
