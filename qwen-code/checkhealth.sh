#!/usr/bin/env bash
# shellcheck shell=bash
# qwen-code/checkhealth.sh — the Qwen Code agent health hook. Sourced by
# checkhealth.sh via run_agent_hook: defines checkhealth_agent_qwen_code()
# and NOTHING ELSE executes at source time (no top-level commands — only
# function definitions).
#
# Failure policy: warn for recoverable problems (services not registered,
# credentials empty, endpoints unreachable — all advisory), non-zero return
# only for real failures (node too old / binary missing / version
# unparsable — the hook wrapper collects them); never exits, never prints a
# secret VALUE.
# ─────────────────────────────────────────────────────────────────────
# _qwen_service_state <unit|label> — prints the resident service state:
#   active | inactive | unregistered | unknown (no usable service manager)
_qwen_service_state() {
	local unit="$1" state=""
	if [ "$(uname -s)" = "Darwin" ]; then
		[ -f "$HOME/Library/LaunchAgents/$unit.plist" ] || {
			printf 'unregistered'
			return 0
		}
		if launchctl print "gui/$(id -u)/$unit" 2>/dev/null | grep -q '"state" = "running"'; then
			printf 'active'
		else
			printf 'inactive'
		fi
	else
		if ! systemd_user_available; then
			printf 'unknown'
			return 0
		fi
		[ -f "$HOME/.config/systemd/user/$unit" ] || {
			printf 'unregistered'
			return 0
		}
		state=$(systemctl --user is-active "$unit" 2>/dev/null) || state=""
		# "activating" under Restart=on-failure means the process dies and
		# systemd keeps restarting it (a crash-loop) — it must NOT read as
		# healthy (is-active also prints "active" briefly between crashes).
		if [ "$state" = "active" ]; then
			printf 'active'
		elif [ "$state" = "activating" ]; then
			printf 'activating'
		else
			printf 'inactive'
		fi
	fi
	return 0
}

# _qwen_service_health <kind> <unit|label> — unified reporter. WARN-only:
# a service that is not registered or not running never fails the health
# run (an unattended machine may legitimately have the resident service
# stopped); it is still surfaced as a WARN.
_qwen_service_health() {
	local kind="$1" unit="$2" state
	state=$(_qwen_service_state "$unit")
	case "$state" in
	active) ok "$kind is running." ;;
	unregistered) warn "$kind is not registered — re-run the installer to register the resident service." ;;
	activating) warn "$kind is crash-looping (systemd keeps restarting it) — check logs: journalctl --user -u $unit (typical cause: credentials missing/incomplete)." ;;
	inactive) warn "$kind is registered but not active — check logs (journalctl --user -u $unit / ~/Library/Logs)." ;;
	*) warn "$kind: no systemd user session — service state unknown (WSL/container?)." ;;
	esac
	return 0
}

# systemd_user_available — 1 when a systemd USER manager is reachable.
# Local copy: the folder checkhealth.sh is sourced standalone.
systemd_user_available() {
	have_native_cmd systemctl || return 1
	systemctl --user show-environment >/dev/null 2>&1
}

# checkhealth_agent_qwen_code — the agent contract function (see lib/agent.sh).
checkhealth_agent_qwen_code() {
	local rc=0

	# Node.js 22+ floor.
	if have_native_cmd node; then
		ok "node version: $(node -v 2>/dev/null)"
		if ! bin_at_least node 22; then
			warn "node is older than 22 — qwen requires Node.js 22+; upgrade it: $(get_install_hint node)"
			rc=1
		fi
	else
		warn "node not found — qwen requires Node.js 22+: $(get_install_hint node)"
		rc=1
	fi

	# Binary + version.
	if have_native_cmd qwen; then
		local ver
		ver=$(extract_version qwen '[0-9]+\.[0-9]+\.[0-9]+[^ ]*')
		if [ -n "$ver" ]; then
			ok "qwen version: $ver"
		else
			warn "qwen found but --version produced no parsable output."
			rc=1
		fi
	else
		warn "qwen binary not found — install it: npm install -g @qwen-code/qwen-code"
		rc=1
	fi

	llm_health qwen QWEN_LLM_API_KEY QWEN_LLM_BASE_URL QWEN_LLM_MODEL "" ""

	# Serve daemon bearer token (token-auth vs token-less posture).
	if [ -n "$(secret QWEN_SERVER_TOKEN 2>/dev/null)" ]; then
		ok "Serve daemon bearer token is set (--require-auth posture)."
	else
		warn "QWEN_SERVER_TOKEN is empty — the serve daemon runs token-less: any local process that can reach 127.0.0.1:4170 can use the operator API (code execution as the daemon user); advisory only."
	fi

	# Resident services (WARN-only — see _qwen_service_health). Unit
	#    names differ per platform: systemd unit files on Linux, launchd
	#    labels (plist basenames) on macOS.
	local svc_serve="qwen-serve.service"
	if [ "$(uname -s)" = "Darwin" ]; then
		svc_serve="com.qwenlm.qwen-serve"
	fi
	_qwen_service_health "qwen-serve service" "$svc_serve"

	# Serve daemon loopback health (advisory) — only probed when the
	#    serve unit is active.
	local code serve_state
	serve_state=$(_qwen_service_state "$svc_serve")
	if [ "$serve_state" = "active" ]; then
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:4170/health 2>/dev/null) || code=""
		if [ "$code" = "200" ]; then
			ok "serve daemon healthy (http://127.0.0.1:4170/health)."
		else
			warn "serve daemon not answering on 127.0.0.1:4170 (HTTP ${code:-none}) — webhook ingress unavailable; advisory only."
		fi
	fi

	# DingTalk channel credentials (channel cannot connect without them).
	if [ -n "$(secret QWEN_DINGTALK_ACCESS_TOKEN 2>/dev/null)" ] && [ -n "$(secret QWEN_DINGTALK_SECRET 2>/dev/null)" ]; then
		ok "DingTalk credentials are set (QWEN_DINGTALK_ACCESS_TOKEN / QWEN_DINGTALK_SECRET)."
	else
		warn "DingTalk credentials incomplete — the channel cannot connect until QWEN_DINGTALK_ACCESS_TOKEN / QWEN_DINGTALK_SECRET are filled (AppKey/AppSecret of a Stream-Mode bot)."
	fi

	# QQ credentials presence (channel type "qq"; empty = QR-code login).
	if [ -n "$(secret QWEN_QQ_APP_ID 2>/dev/null)" ] && [ -n "$(secret QWEN_QQ_APP_SECRET 2>/dev/null)" ]; then
		ok "QQ Bot credentials are set (QWEN_QQ_APP_ID / QWEN_QQ_APP_SECRET)."
	else
		warn "QQ Bot credentials not set — the qq channel will fall back to QR-code login on first start (scan with the phone app), or fill QWEN_QQ_APP_ID / QWEN_QQ_APP_SECRET (QQ Bot Open Platform)."
	fi
	# Channel reachability (outbound WebSocket; route-level probes).
	channel_reachability qwen QWEN_DINGTALK_ACCESS_TOKEN https://api.dingtalk.com DingTalk
	channel_reachability qwen QWEN_QQ_APP_SECRET https://api.sgroup.qq.com "QQ Bot"

	return "$rc"
}
