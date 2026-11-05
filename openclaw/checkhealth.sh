#!/usr/bin/env bash
# shellcheck shell=bash
# openclaw/checkhealth.sh — the OpenClaw agent health hook. Sourced by
# checkhealth.sh via run_agent_hook: defines checkhealth_agent_openclaw() and
# NOTHING ELSE executes at source time (no top-level commands — only
# function definitions).
#
# Checks, in order:
#   1. node 26.12+  (OpenClaw's runtime floor — HIGHER than the other agents'
#      22+; WARN + non-zero when older)
#   2. binary + version   (`openclaw --version`)
#   3. llm_health         (secrets presence + LLM-endpoint connectivity,
#      resolved through the OPENCLAW_LLM_* override layer; names only, never
#      values; an LLM-endpoint failure is recorded via record_agent_failure
#      and counts toward checkhealth's exit code, but the hook itself still
#      returns 0 for it)
#   4. credentials presence (DingTalk clientId/clientSecret + QQ Bot pair;
#      the optional gateway control-plane token — WARN if empty)
#   5. gateway status     (`openclaw gateway status` when the binary exists —
#      WARN if it reports problems; the daemon listens on 127.0.0.1:18790)
#   6. resident service   (service_health from lib/agent.sh — WARN-only)
#   7. channel reachability (api.dingtalk.com / api.sgroup.qq.com probes; the
#      plugins connect outbound, so plain reachability is the meaningful check)
#
# Connectivity skip switch: export SKIP_CONNECTIVITY=1 (advisory downgrade for
# offline machines). Picked over a CLI flag because agent hooks receive no
# arguments from the entry points.
#
# Failure policy: warn for recoverable problems, non-zero return only for
# real failures (node too old / binary missing / version unparsable — the
# hook wrapper collects it); never exits, never prints a secret VALUE.

# checkhealth_agent_openclaw — the agent contract function (see lib/agent.sh).
checkhealth_agent_openclaw() {
	local rc=0
	local svc_unit=openclaw-gateway.service svc_label=com.openclaw.gateway

	# Upstream openclaw engines allow the 24 and 26 tracks; we standardize on
	# the 26 track, which is why this floor is above the family's Node 22.
	node_floor_check OpenClaw 26.12 || rc=1
	binary_version_check openclaw '[0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]+\)' \
		"npm install -g openclaw@latest (or: curl -fsSL https://openclaw.ai/install.sh | bash)" || rc=1

	llm_health openclaw OPENCLAW_LLM_API_KEY OPENCLAW_LLM_BASE_URL OPENCLAW_LLM_MODEL "" "" "" \
		"$HOME/.config/agent/openclaw/openclaw.json" json:models.providers.custom.models

	if secret_pair_set OPENCLAW_DINGTALK_ACCESS_TOKEN OPENCLAW_DINGTALK_SECRET; then
		ok "DingTalk credentials are set (OPENCLAW_DINGTALK_ACCESS_TOKEN / OPENCLAW_DINGTALK_SECRET)."
	else
		warn "DingTalk credentials incomplete — the channel cannot connect until OPENCLAW_DINGTALK_ACCESS_TOKEN / OPENCLAW_DINGTALK_SECRET are filled (AppKey/Client ID and AppSecret/Client Secret of the DingTalk bot)."
	fi
	if secret_pair_set OPENCLAW_QQ_APP_ID OPENCLAW_QQ_CLIENT_SECRET; then
		ok "QQ Bot credentials are set (OPENCLAW_QQ_APP_ID / OPENCLAW_QQ_CLIENT_SECRET)."
	else
		warn "QQ Bot credentials not set — the qqbot channel cannot connect until OPENCLAW_QQ_APP_ID / OPENCLAW_QQ_CLIENT_SECRET / OPENCLAW_QQ_ALLOW_FROM are filled (QQ Bot Open Platform, q.qq.com)."
	fi
	if [ -n "$(secret OPENCLAW_GATEWAY_TOKEN 2>/dev/null)" ]; then
		ok "Gateway control-plane token is set (token-auth posture)."
	else
		warn "OPENCLAW_GATEWAY_TOKEN is empty — the gateway runs token-less: any local process that can reach 127.0.0.1:18790 can drive the assistant (dashboard + full agent API); advisory only."
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

	# Resident service (WARN-only).
	service_health "openclaw gateway service" "$svc_unit" "$svc_label"

	# Channel reachability (outbound WebSocket; route-level probes).
	channel_reachability openclaw OPENCLAW_DINGTALK_ACCESS_TOKEN https://api.dingtalk.com DingTalk
	channel_reachability openclaw OPENCLAW_QQ_CLIENT_SECRET https://api.sgroup.qq.com "QQ Bot"

	return "$rc"
}
