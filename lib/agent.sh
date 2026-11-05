#!/usr/bin/env bash
# shellcheck shell=bash
# Shared agent helpers, used by every agent folder and both entry points
# (install.sh / checkhealth.sh). Sourced AFTER the framework so the
# ok/info/warn/fail output helpers are available; single file by design.
#
# Local state layout — everything lives OUTSIDE this repo checkout:
#   AGENT_HOME    ~/.config/agent          rendered configs + secrets.env
#   SECRETS_FILE  $AGENT_HOME/secrets.env  0600, gitignored, the single
#                 machine-local values file (keys, endpoints, model ids)
#
# Conventions:
#   - No secret value ever travels on a command line or into a log line:
#     helpers hand values over through the environment and files only.
#   - Existing secrets.env values win over the install-time environment:
#     idempotent re-runs never clobber hand-edited values.
#   - A missing secret never blocks the install: templates are written
#     empty so they can be hand-filled after the fact.

# Root of THIS repo's checkout (lib/ lives one level down): agent folders
# are resolved relative to it, so hooks always run from the same revision
# as the entry point that sourced this file — curl|bash re-execs into the
# fresh INSTALL_DIR checkout first, so BASH_SOURCE is trustworthy here.
AGENT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_HOME="${AGENT_HOME:-$HOME/.config/agent}"
SECRETS_FILE="${SECRETS_FILE:-$AGENT_HOME/secrets.env}"

# ──────────────────────── collected failures ────────────────────────
# AGENT_FAILURES — global list of agent failures collected during a run.
# Per the design's degradation goal, a broken agent or render NEVER stops
# the run (not even under the installer's fail-fast fail() semantics): the
# failure is warned here and surfaced at the end — install.sh's
# install_step_after appends the list to SUMMARY_LINES.
AGENT_FAILURES=()

# record_agent_failure <message> — the single funnel for agent failure
# reporting: warn (never fatal) plus AGENT_FAILURES for the end-of-run
# summary.
record_agent_failure() {
	AGENT_FAILURES+=("$1")
	warn "$1"
}

# ──────────────────────── variable-name guard ────────────────────────
# Every helper below evals the names it is handed; keep shell metacharacters
# out before that happens.
_check_var_name() {
	case "$1" in
	'' | *[!A-Za-z0-9_]*)
		die "invalid variable name: '$1'"
		;;
	esac
}

# ──────────────────────── secrets.env ────────────────────────
# load_secrets — source SECRETS_FILE when it exists. Sourcing means values
# already in the file overwrite any same-named environment value: the file
# wins, exactly the precedence the re-run guarantee needs.
load_secrets() {
	[ -f "$SECRETS_FILE" ] || return 0
	# shellcheck source=/dev/null
	. "$SECRETS_FILE"
}

# _file_value <VARNAME> — the value <VARNAME> has in SECRETS_FILE only
# (empty when the file is missing, broken, or does not define the var).
# NO environment fallback: write_secrets_template uses this to distinguish
# "already stored in the file" from "only in the env" (fill-empty-only
# idempotency). The var is unset inside the subshell first — exported
# install-time values must not masquerade as file contents.
_file_value() {
	local var="$1" val=""
	if [ -f "$SECRETS_FILE" ]; then
		# shellcheck disable=SC1090  # user-local file, sourced by design
		val=$(
			set -a
			unset "$var" 2>/dev/null || true
			. "$SECRETS_FILE" >/dev/null 2>&1
			eval 'printf %s "${'"$var"':-}"'
		) || val=""
	fi
	printf '%s' "$val"
}

# secret <VARNAME> [FALLBACK_VAR...] — print the first non-empty resolved
# value among the named vars to stdout (all empty: empty stdout, always
# exit 0 so callers under `set -e` are safe). Per var, a non-empty
# secrets.env value wins over the inherited environment (file read via
# _file_value: subshell containment, half-written/broken files cannot
# poison the caller). The variadic fallback is the §4.2 override layer:
#   secret OPENCODE_LLM_API_KEY LLM_API_KEY
# means the agent-specific value overrides the shared backend; a single
# name is a plain lookup. Reads are logged as set/unset only — never the
# value; the log line goes to stderr so stdout stays pure value.
secret() {
	local v val=""
	for v in ${@+"$@"}; do
		_check_var_name "$v"
		val=$(_file_value "$v")
		[ -n "$val" ] || val=$(eval 'printf %s "${'"$v"':-}"')
		[ -n "$val" ] && break
	done
	if [ -n "$val" ]; then
		printf '%s\n' "$val"
	else
		warn "secret $* is not set (export it before installing, or add it to ${SECRETS_FILE#"$HOME"/})" >&2
	fi
}

# write_secrets_template <varname>... — create or complete SECRETS_FILE
# (0600) as a thin wrapper over "render fill": secrets.env.template seeds a
# fresh file (grouped comments included, so it carries its own
# documentation), hand-edited values in an existing file always win, empty
# KEY= lines are filled from the environment, missing keys are appended.
# Values are written RAW — one containing whitespace or quotes must be
# filled by hand (render warns; realistic credentials never trip this),
# because the file is sourced by the shell.
write_secrets_template() {
	local var
	for var in "$@"; do
		_check_var_name "$var"
	done
	render_fill "$AGENT_REPO_ROOT/secrets.env.template" "$SECRETS_FILE" "$@"
}

# ──────────────────────── config rendering ────────────────────────
# llm_presence <KEY_OVERRIDE> <BASE_OVERRIDE> <MODEL_OVERRIDE> <fill_hint> <fallback_note>
# — the shared "secrets presence" section behind every agent's health
# hook: ok/warn lines (names only, never values) for the LLM API key and
# the base URL + model pair, resolved through the agent's override layer
# via secret(). <fill_hint> extends the fill instructions (e.g. " (or
# ~/.qwen/.env)"); <fallback_note> documents what the rendered config
# falls back to when the secrets stay empty ("" when nothing to add).
llm_presence() {
	local ko="$1" bo="$2" mo="$3" fill_hint="$4" fallback_note="$5"
	if [ -n "$(secret "$ko" LLM_API_KEY 2>/dev/null)" ]; then
		ok "LLM API key is set ($ko or the shared LLM_API_KEY)."
	else
		warn "LLM API key is empty — fill $ko or LLM_API_KEY in ${SECRETS_FILE#"$HOME"/}$fill_hint, then re-run the installer."
	fi
	if [ -n "$(secret "$bo" LLM_BASE_URL 2>/dev/null)" ] && [ -n "$(secret "$mo" LLM_MODEL 2>/dev/null)" ]; then
		ok "LLM base URL / model are set."
	else
		warn "LLM base URL / model not fully set — fill $bo / $mo (or LLM_*) in ${SECRETS_FILE#"$HOME"/}$fill_hint for a private backend.$fallback_note"
	fi
}

# connectivity_check <label> <BASE_OVERRIDE> <KEY_OVERRIDE> [RENDERED_FALLBACK_FN]
# — the shared LLM endpoint probe behind every agent's health hook: GET
# <baseURL>/models with a ~10s timeout. The base URL and the API key
# resolve via secret() (<BASE_OVERRIDE> / shared LLM_BASE_URL;
# <KEY_OVERRIDE> / shared LLM_API_KEY). When the secret layer yields no
# base URL and <RENDERED_FALLBACK_FN> is given, that function is called to
# read the base URL from the agent's rendered config (the local product —
# its public default); pass nothing for agents without one.
# The API key is written to a 0600 temp file and handed to curl via
# `-H @file`, never on a command line (no secret value in the process
# list). On failure: record_agent_failure (warn + the collected list) and
# a non-zero return — the hooks guard the call with `|| true`, so the health
# run itself still returns 0. No base URL from either source: silent skip
# (nothing to probe). <label> prefixes the collected failure line
# ("opencode", "dsh", ...).
connectivity_check() {
	local label="$1" base="" code hdr
	if [ "${SKIP_CONNECTIVITY:-0}" = 1 ]; then
		info "SKIP_CONNECTIVITY=1 — skipping the LLM endpoint check."
		return 0
	fi
	base=$(secret "$2" LLM_BASE_URL 2>/dev/null)
	if [ -z "$base" ] && [ -n "${4:-}" ]; then
		base=$("$4" 2>/dev/null) || base=""
	fi
	if [ -z "$base" ]; then
		info "LLM base URL is unset — connectivity check skipped."
		return 0
	fi
	local key
	key=$(secret "$3" LLM_API_KEY 2>/dev/null)
	hdr=$(mktemp) || {
		warn "connectivity check skipped (mktemp failed)."
		return 0
	}
	local -a curl_args=(-s -o /dev/null -w '%{http_code}' --max-time 10)
	if [ -n "$key" ]; then
		printf 'Authorization: Bearer %s\n' "$key" >"$hdr"
		chmod 600 "$hdr"
		curl_args+=(-H "@$hdr")
	fi
	code=$(curl "${curl_args[@]}" "$base/models") || code=""
	rm -f "$hdr"
	if [ "$code" = "200" ]; then
		ok "LLM endpoint reachable ($base/models)."
	else
		record_agent_failure "$label: LLM endpoint $base/models not reachable (HTTP ${code:-none})"
		return 1
	fi
	return 0
}

# ──────────────────────── links & shell wiring ────────────────────────

# wire_secrets_profile — wire the secrets file into the shell environment via
# the framework's append_env_block (marker-guarded, once): zsh → ~/.zprofile,
# bash → ~/.bash_profile/.profile + ~/.bashrc. Family convention — other
# components' env blocks land the same way. The marker STRING is deployed in
# existing profiles; do not reword it or re-runs would duplicate the block.
wire_secrets_profile() {
	# set -a: the sourced KEY=value lines must land in the ENVIRONMENT
	# (exported) — opencode's {env:VAR}, dsh web's apiKeyEnv and interactive
	# qwen all read the process environment; a bare source would leave them
	# as shell-only variables invisible to every child process.
	# head class: the partition (append_env_block) keeps this block ahead
	# of every normal/tail block — the exec-terminator ordering is the
	# framework's partition rule now, not this repo's content matching.
	# tmux coverage comes FREE from the family's tmux config: Linux leaves
	# default-command empty, so every new window is a LOGIN shell and reads
	# .zprofile itself (a fresh window yields the secrets with the server env unset)
	# — no snapshot mirroring into the running server, which would only add a divergence surface.
	append_env_block "agent secrets (remove these two lines to disable)" \
		'[[ -f "$HOME/.config/agent/secrets.env" ]] && { set -a; source "$HOME/.config/agent/secrets.env"; set +a; }' "head"
}

# models.dev catalog cache: fetched once per install process, shared by
# every hook's capability resolution (in-memory only; no disk cache).
_MODELSDEV_JSON=""
_MODELSDEV_FAILURES=0

# Conservative limits for a model the catalog says nothing about — including
# the whole-catalog-unreachable case, where EVERY model lands here. The
# undershoot is deliberate: an over-declared window can 400 every request, an
# under-declared one only compacts earlier. The python below reads them so the
# floor lives in exactly one place.
LLM_FLOOR_CONTEXT=128000
LLM_FLOOR_OUTPUT=32768

# Function-first: retry's function-export path requires it (a bare
# binary name would hit `export -f <binary>` errors in some shells).
modelsdev_curl() {
	curl -fsSL --max-time 45 https://models.dev/api.json 2>/dev/null
}

modelsdev_fetch() {
	# Positive cache only: a good catalog is fetched once per run and every
	# later caller inherits it (the caller must be in this shell, not a $(…)
	# substitution — see the per-hook prewarm below).
	[ -n "$_MODELSDEV_JSON" ] && return 0
	local prof=(-n 4 -d 15 -m 60 -t 60)
	# A failure is never sticky. One bad sequence must not degrade the rest of
	# the run: on this machine a real install resolved zero models for opencode
	# and dsh and five for openclaw and qwen minutes later in the SAME process,
	# i.e. the proxy blipped and recovered. After the first miss, later requests
	# still try — just with one cheap attempt instead of the full backoff, so a
	# genuinely dead catalog can't cost four agents × minutes.
	[ "$_MODELSDEV_FAILURES" -gt 0 ] && prof=(-n 1 -t 60)
	if _MODELSDEV_JSON=$(retry "${prof[@]}" -s "models.dev catalog" modelsdev_curl); then
		_MODELSDEV_FAILURES=0
		return 0
	fi
	# The resolver still emits floor limits for every id (configs never lose
	# their models); retry already reported each failed attempt, so summarize
	# only the first miss — the later ones are the same news.
	_MODELSDEV_JSON=""
	_MODELSDEV_FAILURES=$((_MODELSDEV_FAILURES + 1))
	if [ "$_MODELSDEV_FAILURES" -eq 1 ]; then
		warn "models.dev catalog unreachable — models fall back to the ${LLM_FLOOR_CONTEXT}/${LLM_FLOOR_OUTPUT} floor until a fetch succeeds; later agents keep retrying, and re-running install is the full retry."
	fi
	return 0
}

# resolve_llm_model_caps <model-id>... — one line per id, in argument order,
# resolved from the cached models.dev catalog (one fetch per batch):
#
#   "<id> <context> <output> <efforts>"
#
#   $ resolve_llm_model_caps zhipu/glm-5.3-flash qwen3-max nosuch/model
#   zhipu/glm-5.3-flash 1000000 131072 low,high,max
#   qwen3-max 262144 65536 -
#   nosuch/model 128000 32768 -
#
# Two catalog paths are read, nothing else: models.<key>.limit.{context,
# output}, and reasoning_options[] entries whose type is "effort" (the other
# declared kinds carry no effort ladder). <efforts> joins that ladder, or "-"
# when the model declares none — callers gate effort config on it.
#
#   { "zhipuai": {                       # provider id = the top-level key
#       "name": "Zhipu AI", "api": "https://open.bigmodel.cn/api/paas/v4",
#       "models": {
#         "glm-5.3-flash": {              # model key form 1: the bare id
#           "limit": { "context": 1000000, "output": 131072 },
#           "reasoning_options": [ { "type": "effort",
#                                    "values": ["low", "high", "max"] } ],
#           "name": ..., "cost": {...}, "tool_call": true, ...
#         }
#       }
#     },
#     "wallaby": { "models": { "moonshotai/kimi-k3": { ... } } },
#     ...                                 # model key form 2: vendor-prefixed
#   }                                     # (a mirror's own naming, not ours)
#
# Matching, best effort, in order:
#   1. a "<vendor>/" request takes the FIRST provider whose top-level key
#      starts with <vendor> and holds a usable entry — a plain string prefix on
#      the PROVIDER key, so a vendor's other brand is invisible to it and a
#      model key's own prefix is never consulted.
#   2. otherwise the first usable carrier in catalog order: deterministic for a
#      given blob, but not vendor-canonical.
# Requests split on the FIRST "/" only, so a request without one has an empty
# vendor and can never take branch 1. Both model key forms are accepted, which
# is why candidates match on (full id, bare name).
# An id with no entry — or an entry without a usable limit — yields the
# conservative 128000/32768 floor with "-". The unusable entry must not count
# as a match or it shadows a usable carrier further down; the floor only costs
# early compaction, while an overshoot can 400 every request.
resolve_llm_model_caps() {
	modelsdev_fetch
	local out
	out=$(printf '%s' "$_MODELSDEV_JSON" | LLM_FLOOR_CONTEXT="$LLM_FLOOR_CONTEXT" \
		LLM_FLOOR_OUTPUT="$LLM_FLOOR_OUTPUT" python3 -c '
import json, os, sys
try:
	db = json.load(sys.stdin)
except Exception:
	# Unreachable or corrupt catalog: keep going with an empty one so every
	# requested id still gets a line (on the floor limits) instead of the
	# whole model list vanishing.
	db = {}
FLOOR = "%s %s" % (os.environ.get("LLM_FLOOR_CONTEXT", "128000"),
                   os.environ.get("LLM_FLOOR_OUTPUT", "32768"))

def caps(meta):
	lim = meta.get("limit") or {}
	ctx, out = lim.get("context"), lim.get("output")
	if not (ctx and out):
		return ""
	efforts = "-"
	for opt in meta.get("reasoning_options") or []:
		if opt.get("type") == "effort" and opt.get("values"):
			efforts = ",".join(str(v) for v in opt["values"])
	return "%s %s %s" % (ctx, out, efforts)

def split(mid):
	head, sep, tail = mid.partition("/")
	return (head, tail) if sep else ("", mid)

def lookup(mid):
	vendor, bare = split(mid)
	matches = []
	for provider, info in db.items():
		for model, meta in (info.get("models") or {}).items():
			if model in (mid, bare):
				found = caps(meta)
				if found:
					matches.append((bool(vendor) and provider.startswith(vendor), found))
	for canonical, found in matches:
		if canonical:
			return found
	return matches[0][1] if matches else ""

for arg in sys.argv[1:]:
	for mid in arg.split(","):
		mid = mid.strip()
		if mid:
			print(mid, lookup(mid) or (FLOOR + " -"))
' "$@" 2>/dev/null) || out=""
	[ -n "$out" ] || return 0
	printf '%s\n' "$out"
}

# resolve_llm_models <primary> -> the agent's effective model list, comma
# separated: <primary> entries first, then every LLM_MODELS entry not already
# listed. An empty <primary> hands the role to LLM_MODELS (order kept);
# LLM_MODEL itself stays the primary (agent-prefix > LLM_MODEL > LLM_MODELS[0]).
# Either side may be a comma LIST — reading the primary as one id is what once
# let a duplicate inside LLM_MODELS survive. Normalization is csv_normalize's.
resolve_llm_models() {
	local catalog="${LLM_MODELS:-}" seeded
	# secrets.env wins over the environment for LLM_MODELS too, exactly like
	# every other value through secret(): reading only the environment made
	# the model list depend on whether the launching shell happened to export
	# it, so the second install run (or a non-login shell) silently rendered
	# fewer models than the file asked for.
	seeded=$(_file_value LLM_MODELS)
	[ -n "$seeded" ] && catalog="$seeded"
	csv_normalize "${1:-},${catalog}"
}

# pick_reasoning_effort <comma-separated-labels> — the reasoning tier to
# configure for a model, empty when it declares none ("-" or blank). Prefers
# "high", falls back to "xhigh": both sit inside the ladder every gateway
# accepts, anything else risks a 400 on the first request.
pick_reasoning_effort() {
	local e
	[ -n "${1:-}" ] && [ "$1" != "-" ] || return 0
	for e in high xhigh; do
		case ",$1," in
		*",$e,"*)
			printf '%s' "$e"
			return 0
			;;
		esac
	done
	return 0
}

# llm_model_rows <primary> -> the effective catalog as one
# "id|context|output|efforts|pick" row per model, no trailing newline (command
# substitution trims it, so a template's range never sees an empty final row;
# templates guard on the empty string too). efforts is "-" when the model
# declares none; pick is the tier to configure (empty = render no effort
# option). This replaced the per-agent loops that hand-concatenated JSON/YAML
# fragments — stray commas, a literal \n and last-one-wins duplicate keys came
# from building structure as strings there.
llm_model_rows() {
	local list caps id ctx out eff pick
	list=$(resolve_llm_models "$1")
	[ -n "$list" ] || return 0
	# resolve_llm_model_caps takes one id per argument: split the comma-joined
	# list here, otherwise the whole list is passed as a single (unknown) id
	# and every model after the primary silently lands on the floor.
	caps=$(resolve_llm_model_caps ${list//,/ })
	while IFS=' ' read -r id ctx out eff; do
		[ -n "$id" ] || continue
		pick=$(pick_reasoning_effort "$eff")
		printf '%s|%s|%s|%s|%s\n' "$id" "$ctx" "$out" "$eff" "$pick"
	done <<<"$caps"
}

# csv_normalize <comma-list> -> the list normalized: per-item leading and
# trailing whitespace stripped, empty items dropped, duplicates dropped (first
# occurrence keeps its place), rejoined with commas. Nothing else: items are
# not sorted, not case-folded, and whitespace inside an item survives. Only
# "," separates, so a value with embedded newlines stays one item.
#
#   $ csv_normalize ' 12345678 , 87654321 ,12345678'   -> 12345678,87654321
#   $ csv_normalize 'a,,b'                              -> a,b
#
# In awk so the caller's IFS is untouched (a shell loop leaked IFS="," into the
# rest of the install function), item text is never pathname-expanded, and the
# trim classes include CR/LF — the here-string appends a newline that RS=","
# leaves INSIDE the last record, where trimming only [ \t] let blanks through.
csv_normalize() {
	LC_ALL=C awk 'BEGIN { RS = ","; sep = "" }
	{
		gsub(/^[ \t\r\n]+/, ""); gsub(/[ \t\r\n]+$/, "")
		if ($0 != "" && !($0 in seen)) { seen[$0] = 1; printf "%s%s", sep, $0; sep = "," }
	}' <<<"$1"
}

# llm_catalog_check <config-file> <count-spec> <MODEL_OVERRIDE> — the rendered
# config must carry as many models as the secrets catalog asks for
# (count-spec: "json:<dotted.path>" or "yaml-ids"). A short count is the
# signature of a catalog that was unreachable at install time. WARN only:
# editing secrets.env without re-running the installer mismatches legitimately
# until the next run, and failing the health run for that would be noise.
llm_catalog_check() {
	local file="$1" spec="$2" key="$3" prim list want have
	[ -f "$file" ] || return 0
	prim=$(secret "$key" LLM_MODEL 2>/dev/null)
	list=$(resolve_llm_models "$prim")
	[ -n "$list" ] || return 0
	want=$(printf '%s' "$list" | tr ',' '\n' | grep -c '[^[:space:]]')
	case $spec in
	json:*)
		have=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
	d = d.get(part) if isinstance(d, dict) else d
print(len(d) if isinstance(d, (list, dict)) else "")
' "$file" "${spec#json:}" 2>/dev/null) || have=""
		;;
	yaml-ids)
		# Count ONLY the "- id:" rows inside the models: block — the file also
		# carries "- id:" rows for plugin patch entries, so a whole-file count
		# over-reports and the check cries wolf.
		have=$(awk '
			function ind(s) { return length(s) - length(substr(s, match(s, /[^[:space:]]/))) }
			/^[[:space:]]*- id:[[:space:]]/ { if (inm) c++; next }
			/^[[:space:]]*models:[[:space:]]*$/ { inm = 1; mi = ind($0); next }
			inm && NF && ind($0) <= mi { inm = 0 }
			END { print c + 0 }
		' "$file" 2>/dev/null) || have=""
		;;
	*) have="" ;;
	esac
	case $have in
	'' | *[!0-9]*) return 0 ;;
	esac
	if [ "$have" -eq 0 ]; then
		warn "$file rendered NO model entries while secrets.env lists $want — models.dev was likely unreachable during install; re-run it."
	elif [ "$have" -ne "$want" ]; then
		warn "$file rendered $have model entries but secrets.env lists $want — re-run the installer to sync."
	fi
	return 0
}

# llm_health <label> <KEY_OVERRIDE> <BASE_OVERRIDE> <MODEL_OVERRIDE> <fill_hint> <fallback_note> [RENDERED_FALLBACK_FN] [CONFIG_FILE] [COUNT_SPEC]
# — the shared LLM half of every agent's health hook: presence, the
# connectivity probe and (when the last two args are given) the rendered model
# count. Params flow straight through to llm_presence, connectivity_check and
# llm_catalog_check (see those for details).
llm_health() {
	local label="$1"
	llm_presence "$2" "$3" "$4" "$5" "$6"
	connectivity_check "$label" "$3" "$2" "${7:-}"
	[ -n "${8:-}" ] && llm_catalog_check "$8" "${9:-}" "$4"
	return 0
}

# secrets_egress_guard — the resident daemons read NO_PROXY from SECRETS_FILE;
# without the loopback binds they send their own 127.0.0.1 serve/gateway ports
# through the proxy, and the symptom (403, timeout, a channel that never
# connects) sits far from the cause. Reports through AGENT_FAILURES so the run
# still finishes and nothing is fatal mid-run. Reads the FILE value, never the
# environment: the installer merges the environment, the units start from the file.
secrets_egress_guard() {
	local np
	[ -f "$SECRETS_FILE" ] || return 0
	np=$(tr -d ' \t\r\n' <<<"$(_file_value NO_PROXY)")
	case ",$np," in
	*,127.0.0.1,*) return 0 ;;
	esac
	if [ -n "$np" ]; then
		record_agent_failure "secrets.env NO_PROXY has no loopback bind (${np}) — the daemons would proxy their own 127.0.0.1 ports; add localhost,127.0.0.1,::1"
	else
		record_agent_failure "secrets.env NO_PROXY is empty — the daemons would proxy their own 127.0.0.1 ports; set localhost,127.0.0.1,::1 (plus any internal hosts)"
	fi
	return 0
}

# channel_reachability <label> <TOKEN_VAR> <probe-url> <service-name> — the
# outbound-network pre-flight for a chat channel: Stream/WebSocket channels
# dial OUT to the vendor (no inbound webhook URL to probe), so plain HTTPS
# reachability of the vendor's API domain is the meaningful network check.
# Any HTTP answer (even 4xx) proves the route; only probed when the
# channel's credentials are set (without them the channel never runs —
# probing would be premature noise). WARN-only: the network is environment,
# not an install error.
channel_reachability() {
	local label="$1" token_var="$2" url="$3" svc="$4"
	[ -n "$(secret "$token_var" 2>/dev/null)" ] || return 0
	local code
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null) || code=""
	if [ -n "$code" ]; then
		ok "$svc API reachable ($url answered HTTP $code)."
	else
		warn "$label: $svc API not reachable (no answer from $url) — the channel cannot connect from this network; advisory only."
	fi
	return 0
}

# systemd_user_available — 1 when a systemd USER manager is actually
# reachable (systemctl present AND the user bus answers). False on
# WSL/containers without systemd: callers skip registration with a WARN.
systemd_user_available() {
	have_native_cmd systemctl || return 1
	systemctl --user show-environment >/dev/null 2>&1
}

# ──────────────────── shared per-agent scaffolding ────────────────────
# The four shapes every agent hook repeats: the Node floor, an npm-delivered
# binary, a credential pair, and one resident service. They live here so a
# change lands once; the agent folders pass names and their own wording.

# node_floor_check <label> <floor> — report the shared Node runtime floor.
# Non-zero when node is missing or below <floor> (a too-old runtime is a real
# failure, not advisory — the caller folds it into its rc).
node_floor_check() {
	local label="$1" floor="$2"
	if ! have_native_cmd node; then
		warn "node not found — $label requires Node.js $floor+: $(get_install_hint node)"
		return 1
	fi
	ok "node version: $(node -v 2>/dev/null)"
	if ! bin_at_least node "$floor"; then
		warn "node is older than $floor — $label requires Node.js $floor+; upgrade it: $(get_install_hint node)"
		return 1
	fi
	return 0
}

# binary_version_check <bin> <version-regex> <install-hint> — the binary must
# exist AND print a version matching <regex>: an unparsable --version is as
# useless to the operator's summary as a missing one.
binary_version_check() {
	local bin="$1" re="$2" hint="$3" ver
	if ! have_native_cmd "$bin"; then
		warn "$bin binary not found — install it: $hint"
		return 1
	fi
	ver=$(extract_version "$bin" "$re")
	if [ -z "$ver" ]; then
		warn "$bin found but --version produced no parsable output."
		return 1
	fi
	ok "$bin version: $ver"
	return 0
}

# secret_pair_set <VAR1> <VAR2> — 0 when BOTH resolve non-empty. Names only,
# never values (secret() reports set/unset to stderr, so stdout stays clean).
secret_pair_set() {
	[ -n "$(secret "$1" 2>/dev/null)" ] && [ -n "$(secret "$2" 2>/dev/null)" ]
}

# llm_resolve <PREFIX> — resolve one agent's effective LLM settings through
# the per-field override layer and fill EFF_KEY_NAME / EFF_BASE / EFF_MODEL /
# EFF_ROWS for the caller to export. render() only substitutes references, it
# cannot apply the precedence itself, so the resolution happens here. The
# API key travels as a NAME (envKey/{env:VAR}/apiKeyEnv indirection) — which
# name is decided here; the values (base URL, model) are public by default and
# machine-local otherwise. EFF_ROWS is the "id|context|output|efforts|pick"
# catalog the templates iterate over.
llm_resolve() {
	local p="$1"
	_check_var_name "$p"
	EFF_KEY_NAME="LLM_API_KEY"
	if [ -n "$(secret "${p}_LLM_API_KEY" 2>/dev/null)" ]; then
		EFF_KEY_NAME="${p}_LLM_API_KEY"
	fi
	EFF_BASE=$(secret "${p}_LLM_BASE_URL" LLM_BASE_URL 2>/dev/null)
	EFF_MODEL=$(secret "${p}_LLM_MODEL" LLM_MODEL 2>/dev/null)
	if [ -z "$(secret "${p}_LLM_API_KEY" 2>/dev/null)" ] &&
		[ -z "$(secret LLM_API_KEY 2>/dev/null)" ]; then
		info "LLM_API_KEY / ${p}_LLM_API_KEY not set — the config references an empty variable; fill ${SECRETS_FILE#"$HOME"/} (or export it before re-running) and re-run."
	fi
	EFF_ROWS=$(llm_model_rows "$EFF_MODEL")
	return 0
}

# npm_agent_install <bin> <npm-spec> <node-floor> <manual-hint> [FALLBACK_FN]
# — the shared install lane: idempotent presence check, then the Node floor
# (ensure_node_at_least returns 0 only once bin_at_least passes, so no second
# probe), then npm_install_g — the framework's prefix/retry/--allow-scripts
# wrapper, one upgrade path for every agent. A successful npm run whose bin is
# not on THIS shell's PATH degrades to a hint (a new shell picks it up).
# [FALLBACK_FN] gets one more attempt before the manual hint.
npm_agent_install() {
	local bin="$1" spec="$2" floor="$3" hint="$4" fb="${5:-}" rc=0
	if have_native_cmd "$bin"; then
		ok "$bin already installed."
		return 0
	fi
	if ! ensure_node_at_least "$floor"; then
		warn "Node.js $floor+ is required but not available — install it manually: $(get_install_hint node)"
		return 1
	fi
	info "Installing $bin (npm_install_g $spec)..."
	npm_install_g "$spec" || rc=$?
	if [ "$rc" -ne 0 ] && [ -n "$fb" ]; then
		rc=0
		"$fb" || rc=$?
	fi
	if [ "$rc" -ne 0 ]; then
		warn "$bin installation failed (rc $rc) — install it manually: $hint"
		return 1
	fi
	if have_native_cmd "$bin"; then
		return 0
	fi
	warn "$bin installed but not on this shell's PATH — open a new shell (npm's global bin directory)."
	return 0
}

# service_state <systemd-unit> <launchd-label> — one vocabulary for both
# platforms: active | activating | inactive | unregistered | unknown.
# "activating" under Restart=on-failure is a crash-loop — the process dies and
# systemd keeps restarting it, and is-active also prints "active" briefly
# between crashes, so it must never read as healthy.
service_state() {
	local unit="$1" label="$2" state=""
	if [ "$(uname -s)" = "Darwin" ]; then
		[ -f "$HOME/Library/LaunchAgents/$label.plist" ] || {
			printf 'unregistered'
			return 0
		}
		if launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -q '"state" = "running"'; then
			printf 'active'
		else
			printf 'inactive'
		fi
		return 0
	fi
	if ! systemd_user_available; then
		printf 'unknown'
		return 0
	fi
	[ -f "$HOME/.config/systemd/user/$unit" ] || {
		printf 'unregistered'
		return 0
	}
	state=$(systemctl --user is-active "$unit" 2>/dev/null) || state=""
	case "$state" in
	active | activating) printf '%s' "$state" ;;
	*) printf 'inactive' ;;
	esac
	return 0
}

# service_health <display-name> <systemd-unit> <launchd-label> — WARN-only
# reporter: an unattended machine may legitimately keep the resident service
# stopped, so nothing here fails the health run — it is still surfaced.
service_health() {
	local kind="$1" unit="$2" label="$3" state
	state=$(service_state "$unit" "$label")
	case "$state" in
	active) ok "$kind is running." ;;
	unregistered) warn "$kind is not registered — re-run the installer to register the resident service." ;;
	activating) warn "$kind is crash-looping (systemd keeps restarting it) — check logs: journalctl --user -u $unit (typical cause: credentials missing/incomplete)." ;;
	inactive) warn "$kind is registered but not active — check logs (journalctl --user -u $unit / ~/Library/Logs)." ;;
	*) warn "$kind: no systemd user session — service state unknown (WSL/container?)." ;;
	esac
	return 0
}

# register_service <systemd-unit> <launchd-label> <render-fn> <manual-hint> —
# platform dispatch plus the whole registration ceremony, shared by every
# resident service:
#   * <render-fn> <dest> renders the platform's unit into <dest>; it owns the
#     export bounding, because a leaked render export would let a later render
#     fill a missing reference from an earlier value instead of aborting.
#   * A failed render skips registration entirely: daemon-reload would load a
#     stale/broken unit into the manager, and macOS must not bootout a working
#     agent on the way to a failed bootstrap.
#   * No usable manager for this platform: WARN + return 0 (nothing to
#     register — the unit renders on a host that has one).
#   * Linux always reloads and always sets linger; the rendered file must not
#     sit unregistered with the manager holding an older copy, and linger keeps
#     the user manager alive for a service enabled later by hand. Enable+start
#     is the only step gated on SECRETS_FILE being non-empty — a daemon without
#     its credential env file crash-loops under Restart=on-failure.
#   * macOS bootstraps only with credentials; bootout first so re-runs replace
#     a previously loaded agent instead of failing.
# Returns non-zero when the manager itself refuses.
register_service() {
	local unit="$1" label="$2" render_fn="$3" hint="$4" dest rc=0
	if [ "$(uname -s)" = "Darwin" ]; then
		if ! have_native_cmd launchctl; then
			warn "launchctl not found — resident service registration skipped; register manually (see the service templates)."
			return 0
		fi
		dest="$HOME/Library/LaunchAgents/$label.plist"
		mkdir -p "$HOME/Library/LaunchAgents"
		if ! "$render_fn" "$dest"; then
			warn "$label.plist render failed — skipping bootout + bootstrap (a stale/broken plist would register). $hint"
			return 1
		fi
		if [ ! -s "$SECRETS_FILE" ]; then
			warn "$label rendered but NOT bootstrapped — secrets.env is missing or empty (the daemon would boot without its credential env file). $hint"
			return 0
		fi
		# A bootstrap of an already-bootstrapped label fails; bootout
		# (best-effort) makes re-runs replace instead of fail.
		launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
		if launchctl bootstrap "gui/$(id -u)" "$dest" >/dev/null 2>&1; then
			ok "$label bootstrapped (launchd user agent)."
		else
			warn "$label bootstrap failed — load manually: launchctl bootstrap gui/$(id -u) $dest"
			rc=1
		fi
		return "$rc"
	fi
	if ! systemd_user_available; then
		warn "No systemd user session (WSL/container?) — skipping resident service registration; the units render on a host with systemd."
		return 0
	fi
	dest="$HOME/.config/systemd/user/$unit"
	mkdir -p "$HOME/.config/systemd/user"
	if ! "$render_fn" "$dest"; then
		warn "$unit render failed — skipping daemon-reload + enable --now (a stale/broken unit would register). $hint"
		return 1
	fi
	if ! systemctl --user daemon-reload; then
		warn "systemctl --user daemon-reload failed — unit rendered but not registered; run it manually."
		return 1
	fi
	if [ -s "$SECRETS_FILE" ]; then
		if systemctl --user enable --now "$unit" 2>/dev/null; then
			ok "$unit enabled and started (systemd user service)."
		else
			warn "$unit registration failed — enable manually: systemctl --user enable --now $unit"
			rc=1
		fi
	else
		warn "$unit rendered but NOT enabled — secrets.env is missing or empty (the daemon would boot without its credential env file). $hint"
	fi
	# Best-effort: some setups gate linger behind polkit auth, which would sit
	# on an interactive prompt in the middle of an unattended install.
	if loginctl enable-linger "$(id -un)" >/dev/null 2>&1; then
		ok "Linger enabled — the service survives logout and reboots."
	else
		info "Linger not enabled (needs auth on some setups) — the service starts at login; enable with: loginctl enable-linger $(id -un)"
	fi
	return "$rc"
}

# ──────────────────────── agent contract ────────────────────────
# Every agent lives in one top-level folder named after it. The folder's
# install.sh defines install_agent_<folder_name_with_underscores>() and its
# checkhealth.sh defines checkhealth_agent_<same>() — the entry points loop
# over ENABLED_AGENTS, source the folder's file and call the function.
# Adding an agent means adding a folder plus its name in ALL_AGENTS; the
# --with-* flags, the default enable set and the usage text all derive from
# this one list, so the skeleton has no per-agent literals left to update.
ALL_AGENTS=(opencode dsh qwen-code openclaw)

# parse_agent_flags "$@" — split an argument list: a --with-<agent> flag
# naming a folder in ALL_AGENTS fills ENABLED_AGENTS (deduped, in flag
# order); everything else — an unknown --with-* included — lands in
# _AGENT_REST for the caller to validate or pass through.
parse_agent_flags() {
	ENABLED_AGENTS=()
	_AGENT_REST=()
	local a i dup
	while [ $# -gt 0 ]; do
		a=""
		case "$1" in
		--with-*)
			for i in ${ALL_AGENTS[@]+"${ALL_AGENTS[@]}"}; do
				if [ "$1" = "--with-$i" ]; then a="$i"; fi
			done
			;;
		esac
		if [ -n "$a" ]; then
			dup=0
			for i in ${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}; do
				if [ "$i" = "$a" ]; then dup=1; fi
			done
			if [ "$dup" -eq 0 ]; then ENABLED_AGENTS+=("$a"); fi
		else
			_AGENT_REST+=("$1")
		fi
		shift
	done
}

# resolve_enabled_agents — apply the "default: every agent in ALL_AGENTS"
# rule after parse_agent_flags.
resolve_enabled_agents() {
	if [ "${#ENABLED_AGENTS[@]}" -gt 0 ]; then return 0; fi
	ENABLED_AGENTS=(${ALL_AGENTS[@]+"${ALL_AGENTS[@]}"})
}

# agent_usage <entry-name> [extra-flags] — the shared usage block of both
# entry points; the flag list is generated from ALL_AGENTS so help can never
# drift from the roster. <extra-flags> is the entry point's own tail
# (checkhealth adds --install / --skip-check-config).
agent_usage() {
	local a flags=""
	for a in ${ALL_AGENTS[@]+"${ALL_AGENTS[@]}"}; do
		flags="$flags [--with-$a]"
	done
	printf 'Usage: %s%s\n\nBy default all supported agents are installed. Pass one or more --with-\nflags to install only the named agents.\n' "$1" "$flags"
	[ -n "${2:-}" ] && printf '%s\n' "$2"
	return 0
}

# run_agent_hook <install|checkhealth> <folder> — source the folder's hook
# file (<folder>/<kind>.sh) and call its contract function
# check<kind>_agent_<folder>. Failure policy (design goal: failures are
# collected and reported at the end, never aborting the run):
#   missing file / no contract function       WARN, move on (the skeleton
#                                             keeps working while agent
#                                             folders land one at a time)
#   broken file / failing hook                record_agent_failure (warn +
#                                             AGENT_FAILURES) naming the
#                                             agent, return 0 — one broken
#                                             agent never stops the run;
#                                             install.sh's summary prints
#                                             the collected list at the end.
run_agent_hook() {
	local kind="$1" folder="$2" file fn
	# Function names prefix the kind: install_agent_* / checkhealth_agent_*.
	file="$AGENT_REPO_ROOT/$folder/$kind.sh"
	fn="${kind}_agent_${folder//-/_}"
	if [ ! -f "$file" ]; then
		warn "${folder}/$(basename "$file") not found in this checkout — skipping $folder."
		return 0
	fi
	# Both the source and the call are guarded (|| rc=$?) so a syntax-broken
	# agent file or a failing hook cannot abort the loop under set -e
	# before the failure is collected.
	local rc=0
	# shellcheck source=/dev/null
	. "$file" || rc=$?
	if [ "$rc" -ne 0 ]; then
		record_agent_failure "agent $folder: $kind.sh is broken (source failed)"
		return 0
	fi
	if declare -F "$fn" >/dev/null 2>&1; then
		"$fn" || rc=$?
		if [ "$rc" -ne 0 ]; then
			record_agent_failure "agent $folder: $fn failed (rc $rc)"
		fi
	else
		warn "$folder/$kind.sh defines no $fn — nothing to do for $folder."
	fi
	return 0
}
