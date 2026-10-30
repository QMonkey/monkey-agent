#!/usr/bin/env bash
# shellcheck shell=bash
# openclaw/checkhealth.sh — the OpenClaw agent health hook. Sourced by
# checkhealth.sh via run_agent_hook: defines checkhealth_agent_openclaw() and
# NOTHING ELSE executes at source time (no top-level commands — only
# function definitions).
#
# Checks, in order:
#   1. node 26.12+  (OpenClaw's runtime floor — HIGHER than the
#      other agents' 22+; WARN + non-zero when older)
#   2. binary + version   (`openclaw --version`)
#   3. llm_health         (secrets presence + LLM-endpoint connectivity,
#      resolved through the OPENCLAW_LLM_* override layer; names only,
#      never values; an LLM-endpoint failure is recorded via
#      record_agent_failure and counts toward checkhealth's exit code,
#      but the hook itself still returns 0 for it)
#   4. credentials presence (DingTalk clientId/clientSecret + QQ Bot pair;
#      the optional gateway control-plane token — WARN if empty)
#   5. gateway status     (`openclaw gateway status` when the binary
#      exists — WARN if it reports problems; the daemon listens on
#      127.0.0.1:18789)
#   6. resident service   (openclaw-gateway.service alive via
#      `systemctl --user is-active`, or launchctl print on macOS; WARN if
#      not registered or not active — advisory, collected failures only)
#   7. channel reachability (api.dingtalk.com / api.sgroup.qq.com probes;
#      the plugins connect outbound, so plain reachability is the
#      meaningful check)
#
# Connectivity skip switch: export SKIP_CONNECTIVITY=1 (advisory downgrade
# for offline machines — design §4.6). Picked over a CLI flag because agent
# hooks receive no arguments from the entry points.
#
# Failure policy: warn for recoverable problems, non-zero return only for
# real failures (node too old / binary missing / version unparsable — the
# hook wrapper collects it); never exits, never prints a secret VALUE.

# _openclaw_rendered_base_url — the OpenAI-compatible base URL from the
# rendered ~/.openclaw/openclaw.json (the local product), empty when the
# file is missing or unparsable. python3 only reads a file path; no
# secrets (the config carries `${VAR}` references, never values).
_openclaw_rendered_base_url() {
	[ -f "$HOME/.openclaw/openclaw.json" ] || return 0
	HOME="$HOME" python3 - <<'PYEOF' 2>/dev/null
import json
import os

try:
    with open(os.path.join(os.environ["HOME"], ".openclaw", "openclaw.json")) as f:
        data = json.load(f)
    print(data["models"]["providers"]["custom"]["baseUrl"])
except Exception:
    pass
PYEOF
}

# _openclaw_service_state — prints the gateway service state:
#   active | inactive | unregistered | unknown (no usable service manager)
_openclaw_service_state() {
	local state=""
	if [ "$(uname -s)" = "Darwin" ]; then
		local label="com.openclaw.gateway"
		[ -f "$HOME/Library/LaunchAgents/$label.plist" ] || {
			printf 'unregistered'
			return 0
		}
		if launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -q '"state" = "running"'; then
			printf 'active'
		else
			printf 'inactive'
		fi
	else
		if ! systemd_user_available; then
			printf 'unknown'
			return 0
		fi
		local unit="openclaw-gateway.service"
		[ -f "$HOME/.config/systemd/user/$unit" ] || {
			printf 'unregistered'
			return 0
		}
		state=$(systemctl --user is-active "$unit" 2>/dev/null) || state=""
		if [ "$state" = "active" ]; then
			printf 'active'
		else
			printf 'inactive'
		fi
	fi
	return 0
}

# _openclaw_service_health — unified reporter. WARN-only: a service that
# is not registered or not running never fails the health run (an
# unattended machine may legitimately have the gateway stopped); it is
# still surfaced as a WARN.
_openclaw_service_health() {
	local state
	state=$(_openclaw_service_state)
	case "$state" in
	active) ok "openclaw gateway service is running." ;;
	unregistered) warn "openclaw gateway service is not registered — re-run the installer to register the resident service." ;;
	inactive) warn "openclaw gateway service is registered but not active — check logs (journalctl --user -u openclaw-gateway.service / ~/Library/Logs/openclaw-gateway)." ;;
	*) warn "openclaw gateway service: no systemd user session — service state unknown (WSL/container?)." ;;
	esac
	return 0
}

# checkhealth_agent_openclaw — the agent contract function (see lib/agent.sh).
checkhealth_agent_openclaw() {
	local rc=0

	# Node 26.12+ floor (OpenClaw-specific — higher than the other
	#    agents' 22+). Upstream openclaw@2026.10.9 engines:
	#    >=24.22.1 <25 || >=26.12.1 — we standardize on the 26 track.
	if have_native_cmd node; then
		ok "node version: $(node -v 2>/dev/null)"
		if ! bin_at_least node 26.12; then
			warn "node is older than OpenClaw's floor (26.12+) — upgrade it (NodeSource / brew upgrade node), then re-run the installer."
			rc=1
		fi
	else
		warn "node not found — OpenClaw requires Node.js 26.12+: $(get_install_hint node)"
		rc=1
	fi

	# Binary + version.
	if have_native_cmd openclaw; then
		local ver
		ver=$(extract_version openclaw '[0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]+\)')
		if [ -n "$ver" ]; then
			ok "openclaw version: $ver"
		else
			warn "openclaw found but --version produced no parsable output."
			rc=1
		fi
	else
		warn "openclaw binary not found — install it: npm install -g openclaw@latest (or: curl -fsSL https://openclaw.ai/install.sh | bash)"
		rc=1
	fi

	# LLM half: presence + connectivity (llm_health — the same call as the
	#    other agents; the sections below are openclaw-specific and
	#    order-independent of it).
	llm_health openclaw OPENCLAW_LLM_API_KEY OPENCLAW_LLM_BASE_URL OPENCLAW_LLM_MODEL "" ""

	if [ -n "$(secret OPENCLAW_DINGTALK_ACCESS_TOKEN 2>/dev/null)" ] && [ -n "$(secret OPENCLAW_DINGTALK_SECRET 2>/dev/null)" ]; then
		ok "DingTalk credentials are set (OPENCLAW_DINGTALK_ACCESS_TOKEN / OPENCLAW_DINGTALK_SECRET)."
	else
		warn "DingTalk credentials incomplete — the channel cannot connect until OPENCLAW_DINGTALK_ACCESS_TOKEN / OPENCLAW_DINGTALK_SECRET are filled (AppKey/Client ID and AppSecret/Client Secret of the DingTalk bot)."
	fi
	if [ -n "$(secret OPENCLAW_QQ_APP_ID 2>/dev/null)" ] && [ -n "$(secret OPENCLAW_QQ_CLIENT_SECRET 2>/dev/null)" ]; then
		ok "QQ Bot credentials are set (OPENCLAW_QQ_APP_ID / OPENCLAW_QQ_CLIENT_SECRET)."
	else
		warn "QQ Bot credentials not set — the qqbot channel cannot connect until OPENCLAW_QQ_APP_ID / OPENCLAW_QQ_CLIENT_SECRET / OPENCLAW_QQ_ALLOW_FROM are filled (QQ Bot Open Platform, q.qq.com)."
	fi
	if [ -n "$(secret OPENCLAW_GATEWAY_TOKEN 2>/dev/null)" ]; then
		ok "Gateway control-plane token is set (token-auth posture)."
	else
		warn "OPENCLAW_GATEWAY_TOKEN is empty — the gateway runs token-less: any local process that can reach 127.0.0.1:18789 can drive the assistant (dashboard + full agent API); advisory only."
	fi

	# Gateway status (WARN-level: `openclaw gateway status` reports the
	#    daemon's state; a failure never fails the health run).
	if have_native_cmd openclaw; then
		local status_out status_rc=0
		status_out=$(openclaw gateway status 2>/dev/null) || status_rc=$?
		if [ "$status_rc" -eq 0 ] && [ -n "$status_out" ]; then
			ok "openclaw gateway status: $(printf '%s' "$status_out" | head -n 1)"
		else
			warn "openclaw gateway status reported problems (rc ${status_rc:-?}) — the gateway may not be running; start it: systemctl --user start openclaw-gateway.service (or openclaw gateway run); advisory only."
		fi
	fi

	# Resident service (WARN-only — see _openclaw_service_health).
	_openclaw_service_health

	# DingTalk reachability (outbound WebSocket; route-level probe).
	channel_reachability openclaw OPENCLAW_DINGTALK_ACCESS_TOKEN https://api.dingtalk.com DingTalk
	channel_reachability openclaw OPENCLAW_QQ_CLIENT_SECRET https://api.sgroup.qq.com "QQ Bot"

	return "$rc"
}
