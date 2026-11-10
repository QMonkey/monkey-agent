#!/usr/bin/env bash
# shellcheck shell=bash
# qwen-code/checkhealth.sh — the Qwen Code agent health hook. Sourced by
# checkhealth.sh via run_agent_hook: defines checkhealth_agent_qwen_code()
# and NOTHING ELSE executes at source time (no top-level commands — only
# function definitions).
#
# The node floor, the binary version and the resident-service state/health
# reports come from lib/agent.sh (node_floor_check, binary_version_check,
# service_state, service_health) — same vocabulary as the other agents.
#
# Failure policy: warn for recoverable problems (services not registered,
# credentials empty, endpoints unreachable — all advisory), non-zero return
# only for real failures (node too old / binary missing / version
# unparsable — the hook wrapper collects them); never exits, never prints a
# secret VALUE.
# ─────────────────────────────────────────────────────────────────────
checkhealth_agent_qwen_code() {
	local rc=0
	local svc_unit=qwen-serve.service svc_label=com.qwenlm.qwen-serve

	node_floor_check qwen 22 || rc=1
	binary_version_check qwen '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' \
		"npm install -g @qwen-code/qwen-code" || rc=1

	llm_health qwen QWEN_LLM_API_KEY QWEN_LLM_BASE_URL QWEN_LLM_MODEL "" "" "" \
		"$AGENT_HOME/qwen/settings.json" json:modelProviders.openai

	# Serve daemon bearer token (token-auth vs token-less posture).
	if [ -n "$(secret QWEN_SERVER_TOKEN 2>/dev/null)" ]; then
		ok "Serve daemon bearer token is set (--require-auth posture)."
	else
		warn "QWEN_SERVER_TOKEN is empty — the serve daemon runs token-less: any local process that can reach 127.0.0.1:4170 can use the operator API (code execution as the daemon user); advisory only."
	fi

	# Resident serve daemon (WARN-only). The systemd unit name and the launchd
	# label are both passed; service_state picks the platform's own.
	service_health "qwen-serve service" "$svc_unit" "$svc_label"

	# Serve daemon loopback health (advisory) — only probed while the service
	# actually runs, so a stopped daemon never reports a second symptom.
	if [ "$(service_state "$svc_unit" "$svc_label")" = "active" ]; then
		local code
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:4170/health 2>/dev/null) || code=""
		if [ "$code" = "200" ]; then
			ok "serve daemon healthy (http://127.0.0.1:4170/health)."
		else
			warn "serve daemon not answering on 127.0.0.1:4170 (HTTP ${code:-none}) — webhook ingress unavailable; advisory only."
		fi
	fi

	# Channel credentials (each adapter cannot connect without its pair).
	if secret_pair_set QWEN_DINGTALK_ACCESS_TOKEN QWEN_DINGTALK_SECRET; then
		ok "DingTalk credentials are set (QWEN_DINGTALK_ACCESS_TOKEN / QWEN_DINGTALK_SECRET)."
	else
		warn "DingTalk credentials incomplete — the channel cannot connect until QWEN_DINGTALK_ACCESS_TOKEN / QWEN_DINGTALK_SECRET are filled (AppKey/AppSecret of a Stream-Mode bot)."
	fi
	if secret_pair_set QWEN_QQ_APP_ID QWEN_QQ_APP_SECRET; then
		ok "QQ Bot credentials are set (QWEN_QQ_APP_ID / QWEN_QQ_APP_SECRET)."
	else
		warn "QQ Bot credentials not set — the qq channel will fall back to QR-code login on first start (scan with the phone app), or fill QWEN_QQ_APP_ID / QWEN_QQ_APP_SECRET (QQ Bot Open Platform)."
	fi

	# Channel reachability (outbound WebSocket; route-level probes).
	channel_reachability qwen QWEN_DINGTALK_ACCESS_TOKEN https://api.dingtalk.com DingTalk
	channel_reachability qwen QWEN_QQ_APP_SECRET https://api.sgroup.qq.com "QQ Bot"

	return "$rc"
}
