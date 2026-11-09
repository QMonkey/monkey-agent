#!/usr/bin/env bash
# shellcheck shell=bash
# qwen-code/install.sh — the Qwen Code agent hook, sourced through
# run_agent_hook: defines install_agent_qwen_code() and nothing else runs
# at source time. Docs: https://qwenlm.github.io/qwen-code-docs/ (npm
# @qwen-code/qwen-code, bin `qwen`, Node.js 22+).
#
# Pitfalls this file encodes:
#   - One credential store: the 0600 agent.env — .zprofile sources it for
#     shells, the unit's EnvironmentFile= for the daemon. settings.json
#     references variables BY NAME (modelProviders envKey, channels $VAR);
#     token security means indirection, never values in the file.
#   - ONE resident daemon: `qwen serve --channel` hosts the loopback
#     HTTP/SSE API (127.0.0.1:4170) and the channel adapters in one
#     process; DingTalk (Stream mode) and QQ Bot are both OUTBOUND
#     WebSocket and are inlined in settings.json.template. Two daemons, or
#     a --channel flag with zero channels, is the failure mode to avoid.
#   - The unit/plist render and the whole registration ceremony live in
#     lib/agent.sh's register_service: a render failure skips registration
#     entirely, because a stale unit would otherwise be loaded and restarted
#     into a crash loop.
_qwen_install_binary() {
	npm_agent_install qwen @qwen-code/qwen-code 22 "npm install -g @qwen-code/qwen-code"
}

# _qwen_render_unit <dest> — render this platform's unit for
# register_service. The subshell bounds these exports (as at every render
# site): a leaked value would let a later render fill a missing reference
# silently. The unit carries an explicit Environment=PATH because systemd
# reads neither the shell's profile nor its PATH; launchd reads no profiles
# either, hence the plist's PATH array. Both are frozen at install — re-run
# install after a PATH change.
_qwen_render_unit() {
	local exports=(QWEN_BIN="$(command -v qwen)" QWEN_SERVE_AUTH_FLAG="$serve_auth_flag" QWEN_CHANNEL_ARGS="$channel_args" QWEN_SERVICE_PATH="$PATH")
	if [ "$(uname -s)" = "Darwin" ]; then
		(
			export "${exports[@]}"
			render \
				"$AGENT_REPO_ROOT/qwen-code/service/com.qwenlm.qwen-serve.plist.template" "$1"
		)
	else
		(
			export "${exports[@]}"
			render \
				"$AGENT_REPO_ROOT/qwen-code/service/qwen-serve.service.template" "$1"
		)
	fi
}

# install_agent_qwen_code — the agent contract function (see lib/agent.sh).
# Failure policy: warns for recoverable problems, returns non-zero on real
# failures (the hook wrapper collects them); never exits, never blocks on a
# missing secret — unset values render as documented fallbacks and health
# flags them later.
install_agent_qwen_code() {
	local rc=0
	mkdir -p "$AGENT_HOME"

	# Binary (Node.js 22+ and npm via the package manager when missing).
	_qwen_install_binary || rc=$?

	# QWEN_SERVER_TOKEN is the optional bearer token for the resident serve
	# daemon. Auth posture (warn, never block): a set token boots serve with
	# --require-auth and reaches it through agent.env (0600); without it the
	# token-less loopback bind exposes the full operator API — code execution
	# as the daemon user — to every local process. The installer
	# auto-generates one into agent.env (fill-empty-only, so a hand-set value
	# always wins); emptying the variable by hand reverts to token-less.
	local serve_auth_flag=""
	if [ -n "$(secret QWEN_SERVER_TOKEN 2>/dev/null)" ]; then
		serve_auth_flag=" --require-auth"
		ok "QWEN_SERVER_TOKEN is set — the serve daemon boots with --require-auth."
	else
		warn "QWEN_SERVER_TOKEN is not set — the serve daemon will run token-less: any local process that can reach 127.0.0.1:4170 can use the full operator API, including executing code as the daemon user. Set QWEN_SERVER_TOKEN and re-run to enable --require-auth."
	fi

	# settings.json is rendered by gomplate, so the per-field override
	# precedence still resolves here — the template only sees resolved values,
	# and the API key reaches it as a NAME (envKey indirection; never values in
	# settings.json). Channel members and the optional reasoningEffort key are
	# structure and live in the template; the working directory is exported raw
	# because the template JSON-escapes it with toJSON.
	llm_resolve QWEN
	local eff_efforts eff_pick
	eff_efforts=$(resolve_llm_model_caps "$EFF_MODEL" | awk 'NR==1 { print $4 }')
	eff_pick=$(pick_reasoning_effort "$eff_efforts")
	# Channel gate flags: the channel worker validates every configured
	# channel at startup and EXITS on the first empty credential, killing the
	# rest with it. No credentials -> "channels": {} -> the daemon boots clean.
	# The flags carry NO secret values — the template embeds the credential
	# NAME ($QWEN_QQ_APP_ID) and the agent resolves it from agent.env at boot.
	local channel_args=""
	if secret_pair_set QWEN_QQ_APP_ID QWEN_QQ_APP_SECRET ||
		secret_pair_set QWEN_DINGTALK_ACCESS_TOKEN QWEN_DINGTALK_SECRET; then
		channel_args=" --channel all"
	fi

	# The subshell is not for `|| rc=$?` (identical either way): it bounds these
	# exports. This hook also renders the service unit, whose template reads some
	# of the SAME names, so a leaked export would let a later render fill a missing
	# reference from an earlier value instead of aborting. Keep the parentheses.
	(
		# Only resolved VALUES are exported. Every reference the template
		# reads must be exported, empty included — gomplate aborts the render
		# on an unset one and reports the offending names. The --channel
		# argument is NOT part of the config contract: only the service unit
		# reads it, so it is not exported here.
		export QWEN_LLM_BASE_URL="$EFF_BASE" QWEN_LLM_MODEL="$EFF_MODEL" \
			QWEN_LLM_API_KEY_ENV_NAME="$EFF_KEY_NAME" \
			QWEN_LLM_MODEL_ROWS="$EFF_ROWS" QWEN_LLM_EFFORT="${eff_pick:-}"
		export QWEN_CHANNEL_CWD="$HOME"
		if secret_pair_set QWEN_QQ_APP_ID QWEN_QQ_APP_SECRET; then
			export QWEN_CHANNEL_QQ=1
		else
			export QWEN_CHANNEL_QQ=""
		fi
		if secret_pair_set QWEN_DINGTALK_ACCESS_TOKEN QWEN_DINGTALK_SECRET; then
			export QWEN_CHANNEL_DINGTALK=1
		else
			export QWEN_CHANNEL_DINGTALK=""
		fi
		render \
			"$AGENT_REPO_ROOT/qwen-code/settings.json.template" \
			"$AGENT_HOME/qwen/settings.json"
	) || rc=$?
	# The gate flags and the unit's --channel all are two views of one fact;
	# drift would start a channel worker with nothing to run (or refuse one
	# it has). Check the rendered config rather than trusting both.
	if [ -f "$AGENT_HOME/qwen/settings.json" ]; then
		local n_chan
		n_chan=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["channels"]))' \
			"$AGENT_HOME/qwen/settings.json" 2>/dev/null) || n_chan=""
		if [ -n "$n_chan" ] && [ "$n_chan" -gt 0 ] && [ -z "$channel_args" ]; then
			record_agent_failure "qwen-code: settings.json renders ${n_chan} channel(s) but the service starts without --channel all — re-run the install"
		elif [ "${n_chan:-0}" -eq 0 ] && [ -n "$channel_args" ]; then
			record_agent_failure "qwen-code: service passes --channel all but settings.json renders no channel — re-run the install"
		fi
	fi
	if [ -f "$AGENT_HOME/qwen/settings.json" ]; then
		mkdir -p "$HOME/.qwen"
		link_config "$AGENT_HOME/qwen/settings.json" "$HOME/.qwen/settings.json" takeover || rc=$?
	fi

	# Resident serve daemon (one process: loopback API + channel adapters).
	# Skipped with a WARN when the binary is missing (that failure is already
	# reported) or when no service manager of the platform is usable — both
	# handled by register_service.
	if have_native_cmd qwen; then
		if ! secret_pair_set QWEN_DINGTALK_ACCESS_TOKEN QWEN_DINGTALK_SECRET; then
			info "DingTalk credentials not set — the dingtalk channel adapter inside the serve daemon will not connect; fill QWEN_DINGTALK_* in ${SECRETS_FILE#"$HOME"/} and restart the service."
		fi
		if ! secret_pair_set QWEN_QQ_APP_ID QWEN_QQ_APP_SECRET; then
			info "QQ Bot credentials not set — the qq channel adapter inside the serve daemon will not connect (falls back to QR-code login on first start); fill QWEN_QQ_* in ${SECRETS_FILE#"$HOME"/} and restart the service."
		fi
		register_service qwen-serve.service com.qwenlm.qwen-serve _qwen_render_unit \
			"Fill agent.env and re-run, or: systemctl --user enable --now qwen-serve.service (launchctl bootstrap gui/$(id -u) on macOS)" || rc=$?
	fi

	return "$rc"
}
