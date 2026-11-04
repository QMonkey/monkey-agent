#!/usr/bin/env bash
# shellcheck shell=bash
# openclaw/install.sh — the OpenClaw agent hook, sourced through
# run_agent_hook: defines install_agent_openclaw() and nothing else runs at
# source time.
#
# Install steps: register this agent's secrets vars (incl. the OPTIONAL
# gateway token) → ensure the binary (Node floor HIGHER than the other
# agents; this file owns the bump path: NodeSource on Linux, brew on macOS,
# WARN+skip rather than breaking the family's Node 22) → install the official
# DingTalk plugin (DingTalk is NOT a core channel) → render config →
# register the gateway service (WARN + skip without a systemd user session,
# e.g. WSL/containers).
#
# Pitfalls this file encodes:
#   - The config is installed as a regular-file COPY at ~/.openclaw/openclaw.json,
#     NOT a symlink: upstream renames atomically onto that path and warns
#     against symlinked layouts.
#   - No secret value is ever rendered: LLM key, DingTalk clientId/clientSecret
#     and the gateway token use OpenClaw's `${VAR}` config substitution; the
#     values arrive through the environment (the unit's EnvironmentFile=
#     hands over secrets.env, which the Gateway also auto-loads).
#   - Strict JSON5 schema: an unknown key makes the Gateway REFUSE TO START
#     (config errors exit 78 on run). A channel key is legal only while its
#     plugin is installed; gateway.auth is injected ONLY when
#     OPENCLAW_GATEWAY_TOKEN is set (token-less loopback otherwise, WARNed).
#   - `cron` (top level) only enables the engine; scheduled jobs are runtime
#     objects (openclaw automations), never config keys.
#   - DingTalk runs INSIDE the Gateway process (outbound WebSocket, plugin
#     requires >= 2026.8.1) — there is no separate resident to supervise.
#   - Because upstream rewrites strip the deployed config's comments, the
#     schema knowledge above lives here, not in the file on disk.
#   - Do NOT also run `openclaw gateway install`: two supervisors would
# _openclaw_install_binary — make sure `openclaw` exists: Node 26.12+ (with
# the bump path above when the distro Node is too old), npm, then the pinned
# npm global install (flag per npm version), falling back to the official
# installer script (--no-onboard: the non-interactive form). Idempotent: a
# present binary short-circuits. Returns non-zero on a real failure (the
# caller's hook wrapper collects it).

#     compete for the same state directory (see the register helpers).
_openclaw_install_binary() {
	if have_native_cmd openclaw; then
		ok "openclaw already installed."
		return 0
	fi
	local rc=0
	# Node.js 26.12+ floor: ensure_node_at_least provisions node
	# meeting the floor (distro packages when new enough, Homebrew — which
	# ships a current node on every platform — when the distro index is too
	# old; the engines corner is enforced by npm itself at install time).
	ensure_node_at_least 26.12 || {
		warn "Node.js 26.12+ is required but not available (found: $(node -v 2>/dev/null || echo none)) — install Node.js 26.12+ manually: $(get_install_hint node)"
		return 1
	}
	# npm_install_g (framework toolchain): ensure_node_and_npm, user-owned prefix
	# and retry, plus the --allow-scripts gating (npm ≥ 11.19 — openclaw
	# ships preinstall + postinstall scripts that new npm would otherwise
	# block).
	info "Installing openclaw (npm_install_g openclaw@latest, https://docs.openclaw.ai/install)..."
	npm_install_g openclaw@latest || rc=$?
	if [ "$rc" -ne 0 ]; then
		rc=0
		# Official fallback (non-interactive form, --no-onboard — pinned
		# 2026-10-24, https://docs.openclaw.ai/install): provisions its own
		# Node/OpenClaw when npm could not.
		info "npm install failed — falling back to the official installer script (--no-onboard)..."
		retry -s "openclaw installer" sh -c 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard' || rc=$?
		if [ "$rc" -ne 0 ]; then
			warn "openclaw installation failed — install it manually: npm install -g openclaw@latest (or: curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard)"
			return 1
		fi
	fi
	if have_native_cmd openclaw; then
		return 0
	fi
	# The install succeeded, so the bin exists — just not on THIS shell's
	# PATH yet (a new shell picks it up).
	warn "openclaw installed but not on this shell's PATH — open a new shell (npm's global bin directory / ~/.local/bin)."
	return 0
}

# _openclaw_install_channel_plugin <npm-spec> <name> — install one official
# channel plugin (DingTalk and QQ Bot are NOT core channels; the channel
# members are injected as static text from install.sh, see the config
# render below). `openclaw plugins install <npm-spec>` is the
# documented non-interactive install path (docs.openclaw.ai/cli/plugins;
# the plugin's own `npx ... install` runs the interactive QR flow, which
# would block). Idempotent: an installed plugin short-circuits.
# Capability consent: an external plugin can require a capability review
# that the installer must NOT silently bypass — on that failure the step
# warns with the exact manual command and returns non-zero. The CALLER
# treats every failure mode (binary missing, install error, trust gate)
# as a degraded success: the config renders without the channel, the
# Gateway still starts, and nothing is collected as an agent failure.
_openclaw_install_channel_plugin() {
	# <npm-spec> <plugin-name> — install one channel plugin (best-effort).
	# Failure is not fatal: the config renders without the channel, the
	# Gateway still starts, and nothing is collected as an agent failure.
	#
	# Non-interactive posture (openclaw 2026.10.9, docs.openclaw.ai/cli/
	# plugins/install): bare specs default to ClawHub, so an external npm
	# plugin needs the explicit npm: prefix. Arbitrary npm sources are gated
	# behind an interactive provenance prompt (--force confirms without
	# prompting) and a capability-consent prompt (--accept-capabilities
	# approves the manifest's declared tools/skills). Both flags are passed
	# deliberately: the specs below are static, pinned constants in this
	# repo whose manifests were reviewed at adoption, and the installer
	# must never sit at an interactive prompt (a retried child cannot read
	# the tty). --pin records the resolved exact version for reproducibility.
	local spec="$1" name="$2"
	if ! have_native_cmd openclaw; then
		warn "openclaw binary not found — skipping the $name plugin install."
		return 1
	fi
	if openclaw plugins list 2>/dev/null | grep -qi "$name"; then
		ok "the $name channel plugin already installed."
		return 0
	fi
	info "Installing the $name channel plugin (openclaw plugins install npm:$spec --force --accept-capabilities --pin — reviewed spec, pinned 2026-10-24, https://docs.openclaw.ai/channels)..."
	if openclaw plugins install "npm:$spec" --force --accept-capabilities --pin; then
		ok "the $name channel plugin installed."
		return 0
	fi
	warn "$name plugin install failed — install it manually after reviewing the prompts: openclaw plugins install npm:$spec --force --accept-capabilities --pin (the plugin's own flow: npx -y $spec install). The config renders WITHOUT the $name channel."
	return 1
}

# _openclaw_register_services_linux — render the unit into
# ~/.config/systemd/user/, daemon-reload, enable --now, linger best-effort.
# Gated on secrets.env: the unit is only enabled+started when secrets.env
# exists and is non-empty (the credential env file the unit's
# EnvironmentFile points at), and a failed render skips the whole
# registration — daemon-reload would load a stale/broken unit into the
# manager.
_openclaw_register_services_linux() {
	# This repo registers its OWN unit — do NOT also run `openclaw gateway
	# install` (the vendor-managed daemon): two supervisors would compete
	# for the same Gateway state directory. Unit shape: Type=simple,
	# Restart=on-failure, absolute ExecStart + PATH frozen at install
	# (systemd reads neither the shell's profile nor the shell's PATH),
	# EnvironmentFile= for credentials (the rendered unit lands 0600 and
	# never inlines secrets; the Gateway also auto-loads the same file as
	# its documented global fallback env source).
	local rc=0 openclaw_bin
	openclaw_bin=$(command -v openclaw)
	# The subshell bounds these exports (as at every render site): a leaked
	# value would let a later render fill a missing reference silently.
	(
		export OPENCLAW_BIN="$openclaw_bin" OPENCLAW_SERVICE_PATH="$PATH" OPENCLAW_CHANNEL_CWD="$HOME"
		render \
			"$AGENT_REPO_ROOT/openclaw/service/openclaw-gateway.service.template" \
			"$unit_dir/openclaw-gateway.service"
	) || rc=$?
	if [ "$rc" -ne 0 ]; then
		warn "openclaw-gateway.service render failed — skipping daemon-reload + enable --now (a stale/broken unit would register). Fix the render error above and re-run, or: systemctl --user daemon-reload && systemctl --user enable --now openclaw-gateway.service"
		return "$rc"
	fi
	local env_ok=1
	if [ ! -s "$HOME/.config/agent/secrets.env" ]; then
		env_ok=0
		warn "openclaw-gateway.service rendered but NOT enabled — secrets.env is missing or empty (the gateway would boot without its credential env file). Fill it and re-run, or: systemctl --user enable --now openclaw-gateway.service"
	fi
	systemctl --user daemon-reload || {
		warn "systemctl --user daemon-reload failed — unit rendered but not registered; run it manually."
		return 1
	}
	if [ "$env_ok" -eq 1 ]; then
		if systemctl --user enable --now openclaw-gateway.service 2>/dev/null; then
			ok "openclaw-gateway.service enabled and started (systemd user service)."
		else
			warn "openclaw-gateway.service registration failed — enable manually: systemctl --user enable --now openclaw-gateway.service"
			rc=1
		fi
	fi
	# Linger keeps the user manager (and the gateway) alive after logout /
	# across reboots — that is the point of a resident personal assistant;
	# best-effort: some setups gate it behind polkit auth, which would hang
	# interactive sudo prompts.
	if loginctl enable-linger "$(id -un)" >/dev/null 2>&1; then
		ok "Linger enabled — the gateway survives logout and reboots."
	else
		info "Linger not enabled (needs auth on some setups) — the gateway starts at login; enable with: loginctl enable-linger $(id -un)"
	fi
	return "$rc"
}

# _openclaw_register_services_macos — render the plist into
# ~/Library/LaunchAgents/ (0600) and bootstrap it into the user's gui
# domain (bootout first so re-runs replace a previously loaded agent).
# Same gates as the Linux path: the agent is only bootstrapped when
# secrets.env exists and is non-empty, and a failed plist render
# skips the whole registration (no bootout, no bootstrap — a previously
# loaded agent keeps running rather than being unloaded onto nothing).
_openclaw_register_services_macos() {
	local rc=0 uid
	local label="com.openclaw.gateway"
	# The plist's PATH (launchd does not read shell profiles): the user's
	# actual PATH, frozen at install — re-run install after PATH changes.
	local openclaw_bin
	openclaw_bin=$(command -v openclaw)
	# The subshell bounds these exports (as at every render site): a leaked
	# value would let a later render fill a missing reference silently.
	(
		export OPENCLAW_BIN="$openclaw_bin" OPENCLAW_SERVICE_PATH="$PATH" OPENCLAW_CHANNEL_CWD="$HOME"
		render \
			"$AGENT_REPO_ROOT/openclaw/service/$label.plist.template" \
			"$agents_dir/$label.plist"
	) || rc=$?
	if [ "$rc" -ne 0 ]; then
		warn "$label.plist render failed — skipping bootout + bootstrap (a stale/broken plist would register). Fix the render error above and re-run, or: launchctl bootstrap gui/$uid $agents_dir/$label.plist"
		return "$rc"
	fi
	if [ ! -s "$HOME/.config/agent/secrets.env" ]; then
		warn "$label rendered but NOT bootstrapped — secrets.env is missing or empty (the gateway would boot without its credential env file). Fill it and re-run, or: launchctl bootstrap gui/$uid $agents_dir/$label.plist"
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

# install_agent_openclaw — the agent contract function (see lib/agent.sh).
# Failure policy: warns for recoverable problems, returns non-zero on real
# failures (the hook wrapper collects them); never exits, never blocks on a
# missing secret — unset values render as documented fallbacks and health
# flags them later.
install_agent_openclaw() {
	local rc=0
	mkdir -p "$AGENT_HOME"

	# Binary (Node 26.12+ floor with the bump path; npm).
	_openclaw_install_binary || rc=$?

	# Channel plugins (dingtalk + qqbot; both need the binary). Failure is
	#    not fatal: the config then renders without the missing channel
	#    members (the strict schema rejects unknown channel keys, so a
	#    member is only emitted when its plugin is installed — the Gateway
	#    would refuse to start otherwise).
	local plugin_dingtalk=0 plugin_qq=0
	if _openclaw_install_channel_plugin @dingtalk-real-ai/dingtalk-connector dingtalk; then
		plugin_dingtalk=1
	fi
	if _openclaw_install_channel_plugin @tencent-connect/openclaw-qqbot qqbot; then
		plugin_qq=1
	fi

	# Config-only, non-interactive equivalent of `openclaw onboard`
	#    (research note atop config.template: a valid config + gateway
	#    service is the documented headless path; the non-interactive
	#    onboard flags exist but pass secrets via argv or require env
	#    plumbing of their own — the config route needs neither).
	#    render resolves references only — it cannot apply the §4.2
	#    per-field override precedence itself, so the effective values are
	#    resolved here and exported (the real secrets.env stays untouched).
	#    Base URL and model are VALUES — public information by default
	#    (DeepSeek's official endpoint, family-consistent fallback
	#    posture) — while the API key and the DingTalk credentials render
	#    as `${VAR}` NAME references only.
	local eff_base eff_model
	# The config's apiKey renders as a ${NAME} reference — resolve WHICH
	# name (the OPENCLAW_LLM_API_KEY override, or the shared LLM_API_KEY).
	local eff_key_name="LLM_API_KEY"
	if [ -n "$(secret OPENCLAW_LLM_API_KEY 2>/dev/null)" ]; then
		eff_key_name="OPENCLAW_LLM_API_KEY"
	fi
	eff_base=$(secret OPENCLAW_LLM_BASE_URL LLM_BASE_URL 2>/dev/null)
	eff_model=$(secret OPENCLAW_LLM_MODEL LLM_MODEL 2>/dev/null)
	# The model catalog: one "id|context|output|efforts|pick" row per model
	# (llm_model_rows in lib/agent.sh) — the template renders the provider's
	# models array from it, including the reasoning flag and the
	# compat.supportedReasoningEfforts ladder (the accepted effort labels from
	# models.dev's reasoning_options; no compat block when the model declares
	# none).
	local model_rows
	model_rows=$(llm_model_rows "$eff_model")
	if [ -z "$(secret OPENCLAW_LLM_API_KEY 2>/dev/null)" ] && [ -z "$(secret LLM_API_KEY 2>/dev/null)" ]; then
		info "LLM_API_KEY / OPENCLAW_LLM_API_KEY not set — the config references an empty variable; fill ${SECRETS_FILE#"$HOME"/} and re-run."
	fi

	# OPENCLAW_GATEWAY_TOKEN is optional (onboarding generates one); when set
	# the config renders gateway.auth in token mode, when empty the loopback
	# Gateway runs token-less (warned below). The auth object is the template's
	# — this only decides the gate flag, and the token travels as a ${VAR}
	# NAME, never a value.
	local gateway_auth=""
	if [ -n "$(secret OPENCLAW_GATEWAY_TOKEN 2>/dev/null)" ]; then
		gateway_auth=1
		ok "OPENCLAW_GATEWAY_TOKEN is set — the gateway boots with token auth."
	else
		warn "OPENCLAW_GATEWAY_TOKEN is not set — the gateway will run token-less: any local process that can reach 127.0.0.1:18790 can drive the assistant (dashboard + full agent API). Set OPENCLAW_GATEWAY_TOKEN and re-run to enable gateway.auth token mode."
	fi
	if [ -z "$(secret OPENCLAW_DINGTALK_ACCESS_TOKEN 2>/dev/null)" ] || [ -z "$(secret OPENCLAW_DINGTALK_SECRET 2>/dev/null)" ]; then
		info "DingTalk credentials not set — the dingtalk-connector channel will not connect; fill OPENCLAW_DINGTALK_* in ${SECRETS_FILE#"$HOME"/} and restart the service."
	fi
	# Channel gate flags — the members themselves live in config.template.
	# Both are gated on plugin presence AND credentials: an empty ${VAR}
	# reference reads as an unresolved SecretRef and the Gateway REFUSES TO
	# START (observed 2026.10.9 crash loop with the member present and the
	# credentials empty). A channel key is legal only while its plugin is
	# installed — the strict schema refuses unknown keys — hence the gate.
	local chan_dingtalk="" chan_qq="" qq_allow=""
	if [ "$plugin_dingtalk" -eq 1 ] &&
		[ -n "$(secret OPENCLAW_DINGTALK_ACCESS_TOKEN 2>/dev/null)" ] && [ -n "$(secret OPENCLAW_DINGTALK_SECRET 2>/dev/null)" ]; then
		chan_dingtalk=1
	fi
	if [ "$plugin_qq" -eq 1 ] &&
		[ -n "$(secret OPENCLAW_QQ_APP_ID 2>/dev/null)" ] && [ -n "$(secret OPENCLAW_QQ_CLIENT_SECRET 2>/dev/null)" ] && [ -n "$(secret OPENCLAW_QQ_ALLOW_FROM 2>/dev/null)" ]; then
		chan_qq=1
		# The allowlist travels as a bare comma list (whitespace stripped,
		# empties and duplicates dropped by csv_normalize) — the template turns it
		# into the JSON array, so no quoting happens here.
		qq_allow=$(csv_normalize "$(secret OPENCLAW_QQ_ALLOW_FROM 2>/dev/null)")
	elif [ "$plugin_qq" -eq 1 ]; then
		info "QQ Bot credentials incomplete — the channel needs OPENCLAW_QQ_APP_ID + OPENCLAW_QQ_CLIENT_SECRET + OPENCLAW_QQ_ALLOW_FROM (comma-separated allowed sender ids); the config renders WITHOUT the qqbot channel."
	fi
	# The subshell is not for `|| rc=$?` (identical either way): it bounds these
	# exports. This hook also renders the service unit, whose template reads some
	# of the SAME names, so a leaked export would let a later render fill a missing
	# reference from an earlier value instead of aborting. Keep the parentheses.
	(
		# Only resolved VALUES are exported. Every reference the template
		# reads must be exported, empty included — gomplate aborts the render
		# on an unset one and reports the offending names.
		export OPENCLAW_WORKSPACE="$HOME/.openclaw/workspace" \
			OPENCLAW_LLM_API_KEY_ENV_NAME="$eff_key_name" \
			OPENCLAW_LLM_BASE_URL="$eff_base" \
			OPENCLAW_PRIMARY_MODEL="custom/$eff_model" \
			OPENCLAW_GATEWAY_AUTH="$gateway_auth" \
			OPENCLAW_LLM_MODEL_ROWS="$model_rows" \
			OPENCLAW_CHANNEL_DINGTALK="$chan_dingtalk" \
			OPENCLAW_CHANNEL_QQ="$chan_qq" \
			OPENCLAW_QQ_ALLOW_FROM="$qq_allow"
		render \
			"$AGENT_REPO_ROOT/openclaw/config.template" \
			"$AGENT_HOME/openclaw/openclaw.json"
	) || rc=$?
	#    Install as a REGULAR FILE COPY (no symlink — upstream renames onto
	#    the config path atomically and says to avoid symlinked layouts;
	#    research note atop config.template). Re-runs overwrite: the
	#    template is the structural truth, hand edits do not survive.
	if [ -f "$AGENT_HOME/openclaw/openclaw.json" ]; then
		mkdir -p "$HOME/.openclaw"
		if [ -L "$HOME/.openclaw/openclaw.json" ]; then
			rm -f "$HOME/.openclaw/openclaw.json"
		fi
		cp "$AGENT_HOME/openclaw/openclaw.json" "$HOME/.openclaw/openclaw.json" || rc=$?
		chmod 600 "$HOME/.openclaw/openclaw.json" 2>/dev/null || true
		ok "Installed ~/.openclaw/openclaw.json (regular file copy — upstream replaces the config atomically)."
	fi

	# Resident gateway service (systemd user unit on Linux, launchd on
	#    macOS). Skipped with a WARN when the binary is missing (that
	#    failure is already reported) or when no service manager of the
	#    platform is usable.
	if have_native_cmd openclaw; then
		if [ "$(uname -s)" = "Darwin" ]; then
			if have_native_cmd launchctl; then
				_openclaw_register_services_macos || rc=$?
			else
				warn "launchctl not found — service registration skipped; register manually (see openclaw/service/ templates)."
			fi
		else
			if systemd_user_available; then
				_openclaw_register_services_linux || rc=$?
			else
				warn "No systemd user session (WSL/container?) — skipping resident service registration; the unit renders on a host with systemd."
			fi
		fi
	else
		warn "openclaw binary not found — skipping resident service registration."
	fi

	return "$rc"
}
