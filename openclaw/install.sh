#!/usr/bin/env bash
# shellcheck shell=bash
# openclaw/install.sh — the OpenClaw agent hook, sourced through
# run_agent_hook: defines install_agent_openclaw() and nothing else runs at
# source time.
#
# Install steps: ensure the binary (Node floor HIGHER than the other agents;
# this file owns the bump path — the distro package when new enough, Homebrew
# otherwise, WARN+skip rather than breaking the family's Node 22) → install
# the official channel plugins (DingTalk is NOT a core channel) → render
# config → register the gateway service.
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
#   - DingTalk runs INSIDE the Gateway process (outbound WebSocket) — there is
#     no separate resident to supervise.
#   - Because upstream rewrites strip the deployed config's comments, the
#     schema knowledge above lives here, not in the file on disk.
#   - This repo registers its OWN unit — do NOT also run `openclaw gateway
#     install` (the vendor-managed daemon): two supervisors would compete for
#     the same Gateway state directory.
_openclaw_install_fallback() {
	# Official installer script (non-interactive form, --no-onboard):
	# provisions its own Node/OpenClaw when the npm lane could not.
	info "npm install failed — falling back to the official installer script (--no-onboard)..."
	retry -s "openclaw installer" sh -c 'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard'
}

_openclaw_install_binary() {
	npm_agent_install openclaw openclaw@latest 26.12 \
		"npm install -g openclaw@latest (or: curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard)" \
		_openclaw_install_fallback
}

# _openclaw_install_channel_plugin <npm-spec> <name> — install one official
# channel plugin (DingTalk and QQ Bot are NOT core channels; the channel
# members are injected as static text from config.template). `openclaw plugins
# install <npm-spec>` is the documented non-interactive install path (the
# plugin's own `npx ... install` runs the interactive QR flow, which would
# block). Idempotent: an installed plugin short-circuits.
#
# Non-interactive posture (openclaw docs.openclaw.ai/cli/plugins/install):
# bare specs default to ClawHub, so an external npm plugin needs the explicit
# npm: prefix. Arbitrary npm sources are gated behind an interactive
# provenance prompt (--force confirms without prompting) and a
# capability-consent prompt (--accept-capabilities approves the manifest's
# declared tools/skills). Both flags are passed deliberately: the specs below
# are static, pinned constants in this repo whose manifests were reviewed at
# adoption, and the installer must never sit at an interactive prompt (a
# retried child cannot read the tty). --pin records the resolved exact version.
# On a capability-review failure the step warns with the exact manual command
# and returns non-zero. The CALLER treats every failure mode (binary missing,
# install error, trust gate) as a degraded success: the config renders without
# the channel, the Gateway still starts, and nothing is collected as an agent
# failure.
_openclaw_install_channel_plugin() {
	local spec="$1" name="$2"
	if ! have_native_cmd openclaw; then
		warn "openclaw binary not found — skipping the $name plugin install."
		return 1
	fi
	if openclaw plugins list 2>/dev/null | grep -qi "$name"; then
		ok "the $name channel plugin already installed."
		return 0
	fi
	info "Installing the $name channel plugin (openclaw plugins install npm:$spec --force --accept-capabilities --pin — reviewed spec, docs.openclaw.ai/channels)..."
	if openclaw plugins install "npm:$spec" --force --accept-capabilities --pin; then
		ok "the $name channel plugin installed."
		return 0
	fi
	warn "$name plugin install failed — install it manually after reviewing the prompts: openclaw plugins install npm:$spec --force --accept-capabilities --pin (the plugin's own flow: npx -y $spec install). The config renders WITHOUT the $name channel."
	return 1
}

# _openclaw_render_unit <dest> — render this platform's gateway unit for
# register_service. The subshell bounds these exports (as at every render
# site): a leaked value would let a later render fill a missing reference
# silently. The unit carries an explicit Environment=PATH because systemd
# reads neither the shell's profile nor its PATH; launchd reads no profiles
# either, hence the plist's PATH array. Both are frozen at install — re-run
# install after a PATH change.
_openclaw_render_unit() {
	(
		export OPENCLAW_BIN="$(command -v openclaw)" OPENCLAW_SERVICE_PATH="$PATH" OPENCLAW_CHANNEL_CWD="$HOME"
		if [ "$(uname -s)" = "Darwin" ]; then
			render \
				"$AGENT_REPO_ROOT/openclaw/service/com.openclaw.gateway.plist.template" "$1"
		else
			render \
				"$AGENT_REPO_ROOT/openclaw/service/openclaw-gateway.service.template" "$1"
		fi
	)
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

	# Config-only, non-interactive equivalent of `openclaw onboard` (a valid
	#    config + gateway service is the documented headless path; the
	#    non-interactive onboard flags exist but pass secrets via argv or
	#    require env plumbing of their own — the config route needs neither).
	#    Base URL and model are VALUES — public information by default,
	#    family-consistent fallback posture — while the API key and the
	#    channel credentials render as `${VAR}` NAME references only.
	llm_resolve OPENCLAW

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
	if ! secret_pair_set OPENCLAW_DINGTALK_ACCESS_TOKEN OPENCLAW_DINGTALK_SECRET; then
		info "DingTalk credentials not set — the dingtalk-connector channel will not connect; fill OPENCLAW_DINGTALK_* in ${SECRETS_FILE#"$HOME"/} and restart the service."
	fi
	# Channel gate flags — the members themselves live in config.template.
	# Both are gated on plugin presence AND credentials: an empty ${VAR}
	# reference reads as an unresolved SecretRef and the Gateway REFUSES TO
	# START. A channel key is legal only while its plugin is installed — the
	# strict schema refuses unknown keys — hence the gate.
	local chan_dingtalk="" chan_qq="" qq_allow=""
	if [ "$plugin_dingtalk" -eq 1 ] &&
		secret_pair_set OPENCLAW_DINGTALK_ACCESS_TOKEN OPENCLAW_DINGTALK_SECRET; then
		chan_dingtalk=1
	fi
	if [ "$plugin_qq" -eq 1 ] &&
		[ -n "$(secret OPENCLAW_QQ_APP_ID 2>/dev/null)" ] &&
		[ -n "$(secret OPENCLAW_QQ_CLIENT_SECRET 2>/dev/null)" ] &&
		[ -n "$(secret OPENCLAW_QQ_ALLOW_FROM 2>/dev/null)" ]; then
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
		# on an unset one and reports the offending names. The model catalog
		# rows carry the reasoning flag and the compat.supportedReasoningEfforts
		# ladder (the accepted effort labels from models.dev's
		# reasoning_options; no compat block when the model declares none).
		export OPENCLAW_WORKSPACE="$HOME/.openclaw/workspace" \
			OPENCLAW_LLM_API_KEY_ENV_NAME="$EFF_KEY_NAME" \
			OPENCLAW_LLM_BASE_URL="$EFF_BASE" \
			OPENCLAW_PRIMARY_MODEL="custom/$EFF_MODEL" \
			OPENCLAW_GATEWAY_AUTH="$gateway_auth" \
			OPENCLAW_LLM_MODEL_ROWS="$EFF_ROWS" \
			OPENCLAW_CHANNEL_DINGTALK="$chan_dingtalk" \
			OPENCLAW_CHANNEL_QQ="$chan_qq" \
			OPENCLAW_QQ_ALLOW_FROM="$qq_allow"
		render \
			"$AGENT_REPO_ROOT/openclaw/config.template" \
			"$AGENT_HOME/openclaw/openclaw.json"
	) || rc=$?
	#    Install as a REGULAR FILE COPY (no symlink — upstream renames onto
	#    the config path atomically and says to avoid symlinked layouts).
	#    Re-runs overwrite: the template is the structural truth, hand edits
	#    do not survive.
	if [ -f "$AGENT_HOME/openclaw/openclaw.json" ]; then
		mkdir -p "$HOME/.openclaw"
		if [ -L "$HOME/.openclaw/openclaw.json" ]; then
			rm -f "$HOME/.openclaw/openclaw.json"
		fi
		cp "$AGENT_HOME/openclaw/openclaw.json" "$HOME/.openclaw/openclaw.json" || rc=$?
		chmod 600 "$HOME/.openclaw/openclaw.json" 2>/dev/null || true
		ok "Installed ~/.openclaw/openclaw.json (regular file copy — upstream replaces the config atomically)."
	fi

	# Resident gateway service (systemd user unit on Linux, launchd on macOS).
	# Skipped with a WARN when the binary is missing (that failure is already
	# reported) or when no service manager of the platform is usable — both
	# handled by register_service.
	if have_native_cmd openclaw; then
		register_service openclaw-gateway.service com.openclaw.gateway _openclaw_render_unit \
			"Fill secrets.env and re-run, or: systemctl --user enable --now openclaw-gateway.service (launchctl bootstrap gui/$(id -u) on macOS)" || rc=$?
	fi

	return "$rc"
}
