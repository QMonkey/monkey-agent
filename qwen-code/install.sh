#!/usr/bin/env bash
# shellcheck shell=bash
# qwen-code/install.sh — the Qwen Code agent hook. Sourced by the entry
# points via run_agent_hook: defines install_agent_qwen_code() and NOTHING
# ELSE executes at source time (no top-level commands — only function
# definitions).
#
# Research (official docs https://qwenlm.github.io/qwen-code-docs/):
#   - Package: npm @qwen-code/qwen-code (bin: `qwen`). Node.js 22+ required.
#   - Credentials: the single 0600 secrets.env (sourced by interactive
#     shells via .zprofile AND fed to the resident daemon via the unit's
#     EnvironmentFile=) — one credential store, no per-agent copies.
#     settings.json references the variables BY NAME (modelProviders
#     envKey + channels $VAR form); token security mandates indirection,
#     never values in settings.json.
#   - Channels (DingTalk Stream-mode bot + QQ Bot, both OUTBOUND
#     WebSocket, inlined in settings.json.template) + the ONE resident
#     daemon `qwen serve --channel` (qwen-serve: loopback API + channel
#     adapters in a single process) — systemd user unit / launchd plist
#     under service/.
#
# _qwen_install_binary — make sure `qwen` exists: Node.js 22+ and npm via
# the framework package manager when missing, then the pinned npm global
# install. Idempotent: a present binary short-circuits. Returns non-zero on
# a real failure (caller's hook wrapper collects it).
_qwen_install_binary() {
	if have_native_cmd qwen; then
		ok "qwen already installed."
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
	info "Installing qwen (npm_install_g @qwen-code/qwen-code — pinned 2026-10-24, https://qwenlm.github.io/qwen-code-docs/users/quickstart/)..."
	# npm_install_g (framework toolchain): ensure_node_and_npm, user-owned prefix,
	# retry, npm ≥ 11.19 --allow-scripts gate. @qwen-code/qwen-code declares
	# no lifecycle scripts today — gate is a no-op, kept for lane consistency.
	npm_install_g @qwen-code/qwen-code || rc=$?
	if [ "$rc" -ne 0 ]; then
		warn "qwen installation failed (rc $rc) — install it manually: npm install -g @qwen-code/qwen-code"
		return 1
	fi
	if have_native_cmd qwen; then
		return 0
	fi
	# npm succeeded, so the bin exists in npm's global prefix — just not on
	# THIS shell's PATH yet (a new shell picks it up).
	warn "qwen installed but not on this shell's PATH — open a new shell (npm's global bin directory)."
	return 0
}

# _qwen_register_services_linux — render the unit into
# ~/.config/systemd/user/, daemon-reload, enable --now, linger best-effort.
# Gated on secrets.env: the unit is only enabled+started when secrets.env
# exists and is non-empty (its credential env file) — without credentials
# the channel adapters inside the daemon would crash-loop under systemd's
# Restart=on-failure (observed live: restart counter >40 within minutes).
# A failed unit render skips the whole registration: daemon-reload would
# load a stale/broken unit into the manager.
_qwen_register_services_linux() {
	# `qwen serve --channel` = ONE resident process: the loopback HTTP+SSE
	# daemon (Web Shell, port 4170) AND the channel adapters. Unit shape
	# mirrors the official local-launch template: Type=simple,
	# Restart=on-failure, absolute ExecStart (systemd does not read the
	# shell's PATH), EnvironmentFile= at the 0600 secrets.env — never
	# inlining the token. AUTH POSTURE: QWEN_SERVER_TOKEN auto-generated
	# at install (fill-empty-only, a hand-set value always wins); the
	# daemon boots with --require-auth. On a token-less loopback bind
	# "any local process that can reach the port can use the full
	# operator API, including executing code as the daemon user" —
	# emptying the variable by hand reverts to token-less (warned).
	local rc=0 qwen_bin
	qwen_bin=$(command -v qwen)
	local unit_dir="$HOME/.config/systemd/user"
	mkdir -p "$unit_dir"
	export QWEN_BIN="$qwen_bin" QWEN_SERVE_AUTH_FLAG="$serve_auth_flag"
	render \
		"$AGENT_REPO_ROOT/qwen-code/service/qwen-serve.service.template" \
		"$unit_dir/qwen-serve.service" || rc=$?
	if [ "$rc" -ne 0 ]; then
		warn "service unit render failed — skipping daemon-reload + enable --now (a stale/broken unit would register). Fix the render error above and re-run, or: systemctl --user daemon-reload && systemctl --user enable --now qwen-serve.service"
		return "$rc"
	fi
	if [ ! -s "$HOME/.config/agent/secrets.env" ]; then
		warn "qwen-serve.service rendered but NOT enabled — secrets.env is missing or empty (the daemon would boot without its credential env file). Fill it and re-run, or: systemctl --user enable --now qwen-serve.service"
		return 0
	fi
	systemctl --user daemon-reload || {
		warn "systemctl --user daemon-reload failed — unit rendered but not registered; run it manually."
		return 1
	}
	if systemctl --user enable --now qwen-serve.service 2>/dev/null; then
		ok "qwen-serve.service enabled and started (systemd user service)."
	else
		warn "qwen-serve.service registration failed — enable manually: systemctl --user enable --now qwen-serve.service"
		rc=1
	fi
	# Linger keeps the user manager (and the service) alive after logout /
	# across reboots; best-effort — some setups gate it behind polkit auth.
	if loginctl enable-linger "$(id -un)" >/dev/null 2>&1; then
		ok "Linger enabled — the service survives logout and reboots."
	else
		info "Linger not enabled (needs auth on some setups) — the service starts at login; enable with: loginctl enable-linger $(id -un)"
	fi
	return "$rc"
}

# _qwen_register_services_macos — render the plist into
# ~/Library/LaunchAgents/ (0600) and bootstrap it into the user's gui
# domain (bootout first so re-runs replace a previously loaded agent).
# Same gate as the Linux path: the agent is only bootstrapped when
# secrets.env exists and is non-empty (a daemon without its credential
# env file would crash-loop under keepalive). A failed plist render
# skips the whole registration (no bootout, no bootstrap).
_qwen_register_services_macos() {
	local rc=0 uid
	local label="com.qwenlm.qwen-serve"
	local agents_dir="$HOME/Library/LaunchAgents"
	mkdir -p "$agents_dir"
	uid=$(id -u)
	# The plist's PATH (launchd does not read shell profiles): the user's
	# actual PATH, frozen at install — re-run install after PATH changes.
	export QWEN_BIN="$(command -v qwen)" QWEN_SERVICE_PATH="$PATH" QWEN_SERVE_AUTH_FLAG="$serve_auth_flag"
	render \
		"$AGENT_REPO_ROOT/qwen-code/service/com.qwenlm.qwen-serve.plist.template" \
		"$agents_dir/$label.plist" || rc=$?
	if [ "$rc" -ne 0 ]; then
		warn "$label.plist render failed — skipping bootout + bootstrap (a stale/broken plist would register). Fix the render error above and re-run, or: launchctl bootstrap gui/$uid $agents_dir/$label.plist"
		return "$rc"
	fi
	if [ ! -s "$HOME/.config/agent/secrets.env" ]; then
		warn "$label rendered but NOT bootstrapped — secrets.env is missing or empty (the daemon would boot without its credential env file). Fill it and re-run, or: launchctl bootstrap gui/$uid $agents_dir/$label.plist"
		return 0
	fi
	# A bootstrap of an already-bootstrapped label fails; bootout
	# (best-effort) makes re-runs replace instead of fail.
	launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
	if launchctl bootstrap "gui/$uid" "$agents_dir/$label.plist" >/dev/null 2>&1; then
		ok "$label bootstrapped (launchd user agent)."
	else
		warn "$label bootstrap failed — load manually: launchctl bootstrap gui/$uid $agents_dir/$label.plist"
		rc=1
	fi
	return "$rc"
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

	# QWEN_SERVER_TOKEN is the optional bearer token for the resident serve daemon.
	# Serve daemon auth posture (research-pinned, see the serve template
	# headers; informed choice, design "warn, never block"): a set
	# QWEN_SERVER_TOKEN boots serve with --require-auth and the token
	# reaches it through secrets.env (0600); without it, the token-less
	# loopback bind exposes the full operator API (code execution as the
	# daemon user) to every local process — WARN.
	local serve_auth_flag=""
	if [ -n "$(secret QWEN_SERVER_TOKEN 2>/dev/null)" ]; then
		serve_auth_flag=" --require-auth"
		ok "QWEN_SERVER_TOKEN is set — the serve daemon boots with --require-auth."
	else
		warn "QWEN_SERVER_TOKEN is not set — the serve daemon will run token-less: any local process that can reach 127.0.0.1:4170 can use the full operator API, including executing code as the daemon user. Set QWEN_SERVER_TOKEN and re-run to enable --require-auth."
	fi

	# The QQ + DingTalk channels are INLINED in settings.json.template.
	# The only dynamic value is the channel working directory, JSON-escaped
	# here for its embedded-string placeholder: backslash + quote (a
	# workspace path has no control chars).
	qwen_cwd_esc="$HOME"
	qwen_cwd_esc=${qwen_cwd_esc//\\/\\\\}
	qwen_cwd_esc=${qwen_cwd_esc//\"/\\\"}

	# settings.json: render is a pure envsubst engine — it cannot apply
	#    the §4.2 per-field override precedence itself, so the effective
	#    values are resolved here and exported (the real secrets.env stays
	#    untouched). Base URL and model are VALUES (public Qwen
	#    endpoint/model by default, machine-local otherwise); the API key
	#    renders as a NAME only (envKey indirection — token security, see
	#    the header above; never values in settings.json).
	local eff_base eff_model
	eff_base=$(secret QWEN_LLM_BASE_URL LLM_BASE_URL 2>/dev/null)
	eff_model=$(secret QWEN_LLM_MODEL LLM_MODEL 2>/dev/null)
	if [ -z "$(secret QWEN_LLM_API_KEY 2>/dev/null)" ] && [ -z "$(secret LLM_API_KEY 2>/dev/null)" ]; then
		info "LLM_API_KEY / QWEN_LLM_API_KEY not set — the config references an empty variable; fill ${SECRETS_FILE#"$HOME"/} and re-run."
	fi
	# Model capability limit (contextWindowSize): resolved from models.dev
	# against the EFFECTIVE model (see resolve_llm_model_caps in lib/agent.sh); a miss
	# lands on the conservative 128000 floor.
	# Effort (settings' model.reasoningEffort): only when the model's
	# reasoning_options (models.dev) declare a safe tier (high, else
	# xhigh) — qwen-code clamps to the model's ladder on top of this.
	local eff_ctx eff_out eff_efforts eff_pick eff_effort_fragment=""
	read -r eff_ctx eff_out eff_efforts <<<"$(resolve_llm_model_caps "$eff_model")"
	eff_pick=$(pick_reasoning_effort "$eff_efforts")
	[ -n "$eff_pick" ] && eff_effort_fragment='"model": { "reasoningEffort": "'"$eff_pick"'" },'
	(
		# The RESOLVED override-layer values are exported here.
		export QWEN_LLM_BASE_URL="$eff_base" QWEN_LLM_MODEL="$eff_model" \
			QWEN_LLM_CTX="$eff_ctx" QWEN_LLM_EFFORT="$eff_effort_fragment"
		export QWEN_CHANNEL_CWD="$qwen_cwd_esc"
		render \
			"$AGENT_REPO_ROOT/qwen-code/settings.json.template" \
			"$AGENT_HOME/qwen/settings.json"
	) || rc=$?
	if [ -f "$AGENT_HOME/qwen/settings.json" ]; then
		mkdir -p "$HOME/.qwen"
		link_config "$AGENT_HOME/qwen/settings.json" "$HOME/.qwen/settings.json" takeover || rc=$?
	fi

	# Resident serve daemon (one process: loopback API + channel
	#    adapters). Skipped with a WARN when the
	#    binary is missing (that failure is already reported) or when no
	#    service manager of the platform is usable.
	if have_native_cmd qwen; then
		#    DingTalk credentials missing → the channel adapter inside serve
		#    cannot connect (warned; the daemon itself still boots —
		#    systemd's start-limit caps any crash-looping).
		if [ -z "$(secret QWEN_DINGTALK_ACCESS_TOKEN 2>/dev/null)" ] || [ -z "$(secret QWEN_DINGTALK_SECRET 2>/dev/null)" ]; then
			info "DingTalk credentials not set — the dingtalk channel adapter inside the serve daemon will not connect; fill QWEN_DINGTALK_* in ${SECRETS_FILE#"$HOME"/} and restart the service."
		fi
		if [ -z "$(secret QWEN_QQ_APP_ID 2>/dev/null)" ] || [ -z "$(secret QWEN_QQ_APP_SECRET 2>/dev/null)" ]; then
			info "QQ Bot credentials not set — the qq channel adapter inside the serve daemon will not connect (falls back to QR-code login on first start); fill QWEN_QQ_* in ${SECRETS_FILE#"$HOME"/} and restart the service."
		fi
		if [ "$(uname -s)" = "Darwin" ]; then
			if have_native_cmd launchctl; then
				_qwen_register_services_macos || rc=$?
			else
				warn "launchctl not found — service units rendered later skipped; register manually (see qwen-code/service/ templates)."
			fi
		else
			if systemd_user_available; then
				_qwen_register_services_linux || rc=$?
			else
				warn "No systemd user session (WSL/container?) — skipping resident service registration; the units render on a host with systemd."
			fi
		fi
	else
		warn "qwen binary not found — skipping resident service registration."
	fi

	return "$rc"
}
