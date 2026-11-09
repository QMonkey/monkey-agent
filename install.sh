#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# monkey-agent one-shot installer
# Usage: curl -fsSL https://raw.githubusercontent.com/QMonkey/monkey-agent/master/install.sh | bash
#
# The shared installer (sudo, packages, clone, checkhealth, symlinks,
# completion) lives in scripts/ — a `git subtree` of
# github.com/QMonkey/monkey-scripts. On the curl|bash path there is no
# checkout at all, so install.sh clones THIS repo and runs the copy of
# install.sh inside it — that copy carries its own scripts/, so the
# installer and the framework it loads are always the same revision.
# ──────────────────────────────────────────────────────────────

# ──────────────────────── repository identity ────────────────────────
# Declared before the framework is sourced: the bootstrap below needs both
# values, and clones into the very directory clone_project would
# have used — one clone per run, not two.
PROJECT=monkey-agent
PROJECT_REPO=https://github.com/QMonkey/monkey-agent.git
INSTALL_DIR="${INSTALL_DIR:-$HOME/Documents/monkey-agent}"

# No scripts/ next to this file: either a checkout predating the subtree
# commit (pull it in and carry on), a .git-less directory (zip/tarball),
# or `curl | bash`, which has no checkout at all. The latter two bootstrap
# through INSTALL_DIR and run the install.sh from that checkout, so
# installer and scripts/ always come from the same revision.
_monkey_scripts="$(dirname "${BASH_SOURCE[0]:-$0}")/scripts"
if [ ! -f "$_monkey_scripts/install.sh" ]; then
	_monkey_self="${BASH_SOURCE[0]:-$0}"
	_monkey_dir="$(dirname "$_monkey_self")"
	if [ -f "$_monkey_self" ] && [ -d "$_monkey_dir/.git" ]; then
		# Outdated checkout: update it in place and keep running from it.
		git -C "$_monkey_dir" pull --ff-only || true
		if [ ! -f "$_monkey_dir/scripts/install.sh" ]; then
			printf '%s\n' "monkey-scripts missing from $_monkey_dir (no scripts/ subtree)." >&2
			printf '%s\n' "  git -C $_monkey_dir pull    # outdated checkout — or the repo never added the subtree" >&2
			exit 1
		fi
		_monkey_scripts="$_monkey_dir/scripts"
	else
		# curl|bash or a .git-less directory: the only path to a
		# same-revision scripts/ is the INSTALL_DIR checkout.
		# clone_project cannot do this job — it lives in the very
		# scripts/ being fetched. INSTALL_DIR is where the framework's clone
		# step would have put the checkout too, so that step only confirms it.
		if [ -d "$INSTALL_DIR/.git" ]; then
			# An install already lives here: update it, then run that one.
			git -C "$INSTALL_DIR" pull --ff-only || true
		elif [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR")" ]; then
			# git clone would refuse too, so say why in our own words.
			printf '%s\n' "$INSTALL_DIR is not empty and is not a git clone." >&2
			printf '%s\n' "  move it aside, delete it, or set INSTALL_DIR elsewhere." >&2
			exit 1
		else
			# Fresh clone — the ONLY sub-branch where git is hard-required:
			# the pull sub-branch above degrades gracefully without it, and
			# a zip/tarball must not fail here just for a missing git.
			if ! command -v git >/dev/null 2>&1; then
				printf '%s\n' "git is required to clone $PROJECT — install it first (e.g. sudo apt-get install git), then re-run." >&2
				exit 1
			fi
			# No retry() available yet — the framework loads only after this
			# clone succeeds — so inline three attempts. A failed
			# clone leaves a partial directory behind; remove it so the next
			# attempt cannot trip over "already exists". This branch only
			# runs on a fresh install (INSTALL_DIR did not exist or was
			# empty), so the rm can never delete pre-existing data.
			_monkey_rc=1
			for _monkey_attempt in 1 2 3; do
				if git clone "$PROJECT_REPO" "$INSTALL_DIR"; then
					_monkey_rc=0
					break
				fi
				rm -rf "$INSTALL_DIR"
				if [ "$_monkey_attempt" -lt 3 ]; then
					sleep 2
				fi
			done
			[ "$_monkey_rc" -eq 0 ] || exit 1
		fi
		# </dev/null: on the curl|bash path stdin is the script pipe, and the
		# inner installer must not read what is left of the outer one.
		exec bash "$INSTALL_DIR/install.sh" "$@" </dev/null
	fi
fi
# shellcheck source=/dev/null
. "$_monkey_scripts/install.sh"

# ──────────────────────── layout & data ────────────────────────
# Shared agent helpers (agent.env, template rendering, links) — sourced
# after the framework so the output helpers exist. Agent folders are
# resolved against the checkout this file lives in (AGENT_REPO_ROOT).
. "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/agent.sh"

usage() { agent_usage "$0"; }

# ──────────────────────── agent selection ────────────────────────
# This entry point accepts ONLY the agent-selection flags: everything the
# splitter hands back is either -h/--help or a usage error. The enable
# set lives in ENABLED_AGENTS (agent folder names, verbatim).
parse_agent_flags "$@"
if [ "${#_AGENT_REST[@]}" -gt 0 ]; then
	case "${_AGENT_REST[0]}" in
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf '%s\n' "Unknown option: ${_AGENT_REST[0]}" >&2
		usage >&2
		exit 2
		;;
	esac
fi
resolve_enabled_agents

# ──────────────────────── project steps ────────────────────────

# Step 1: the shared local-state scaffolding, agent-independent:
# ~/.config/agent/ and ~/.config/env/agent.env (written with or without
# values — the install never blocks on a missing secret), and the .zprofile
# source line.
install_shared_secrets() {
	mkdir -p "$AGENT_HOME"
	# Daemon tokens: auto-generate when unset — a random secret is the
	# upstream-default posture (openssl rand -hex 32), and without one the
	# resident daemons run token-less (the local operator API — code
	# execution as the daemon user — is exposed to every local process).
	# Gated on the agent being enabled; fill-empty-only means a
	# user-supplied or hand-edited value always wins, and the generated
	# value persists HERE (the single source of truth) so re-runs never
	# rotate it behind the user's back.
	local a tok generated=""
	for a in ${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}; do
		tok=""
		case "$a" in
		qwen-code) tok=QWEN_SERVER_TOKEN ;;
		openclaw) tok=OPENCLAW_GATEWAY_TOKEN ;;
		esac
		if [ -n "$tok" ] && have_native_cmd openssl &&
			[ -z "$(secret "$tok" 2>/dev/null)" ]; then
			export "$tok=$(openssl rand -hex 32)"
			generated="$generated $tok"
		fi
	done
	if [ -n "$generated" ]; then
		info "Auto-generated daemon tokens:$generated (openssl rand -hex 32; rotate by hand in ${SECRETS_FILE#"$HOME"/})."
	fi
	# NO_PROXY is ADDITIVE by nature (exclusions only grow): the caller's
	# entries keep their order and the loopback binds are appended only when
	# missing. This merge is the ONLY source of that floor — the template
	# leaves the line empty so fill mode takes this value instead of a seeded
	# default — so it must stay ahead of write_secrets_template below.
	# checkhealth guards the floor in the file (warn, never rewrite).
	local _np="${NO_PROXY:-}" _d
	for _d in localhost 127.0.0.1 ::1; do
		case ",$_np," in
		*,"$_d,"*) ;;
		*) _np="${_np:+$_np,}$_d" ;;
		esac
	done
	export NO_PROXY="$_np"
	write_secrets_template \
		LLM_API_KEY LLM_BASE_URL LLM_MODEL LLM_MODELS \
		OPENCODE_LLM_API_KEY OPENCODE_LLM_BASE_URL OPENCODE_LLM_MODEL \
		DSH_LLM_API_KEY DSH_LLM_BASE_URL DSH_LLM_MODEL \
		QWEN_LLM_API_KEY QWEN_LLM_BASE_URL QWEN_LLM_MODEL \
		OPENCLAW_LLM_API_KEY OPENCLAW_LLM_BASE_URL OPENCLAW_LLM_MODEL \
		QWEN_QQ_APP_ID QWEN_QQ_APP_SECRET \
		QWEN_DINGTALK_ACCESS_TOKEN QWEN_DINGTALK_SECRET QWEN_SERVER_TOKEN \
		OPENCLAW_DINGTALK_ACCESS_TOKEN OPENCLAW_DINGTALK_SECRET \
		OPENCLAW_QQ_APP_ID OPENCLAW_QQ_CLIENT_SECRET OPENCLAW_QQ_ALLOW_FROM \
		OPENCLAW_GATEWAY_TOKEN \
		HTTPS_PROXY HTTP_PROXY NO_PROXY
	wire_secrets_profile
}

install_step_prepare() {
	ensure_git
	# Provision the renderer before install_step_tool, where its consumers
	# run: every agent hook renders its config and its service unit with
	# gomplate, while the framework's dependency pass runs AFTER that step —
	# so a host that never had gomplate failed every render yet still
	# finished green. ensure_git comes first because a lane may have to clone
	# Homebrew. install_pkg, not install_strategy: this process loads no
	# lib/checks.sh, so probe_spec does not exist, and probe_spec is exactly
	# what makes install_strategy stop — called here it would walk every lane
	# and report failure even after a bottle landed. The guard is load-bearing
	# because install_pkg does not skip a name that is already installed, so
	# without it every re-run re-asks the chain. Not fatal on purpose: the
	# hooks still install their agent binaries, and each render failure is
	# collected and named.
	have_native_cmd gomplate || install_pkg gomplate ||
		record_agent_failure "gomplate unavailable before the agent step — no agent config can render; install it and re-run"
	install_shared_secrets
	# Warm the models.dev cache once, here, in the installer process — this is
	# the one place that works: install_step_tool → run_agent_hook calls each
	# hook in THIS shell, so every enabled agent inherits what this single
	# fetch stores, while a fetch inside $(llm_model_rows …) would die with its
	# subshell. The fallback inside resolve_llm_model_caps stays for callers
	# that skip this step; a failure is never sticky, so each agent still gets
	# a cheap probe.
	modelsdev_fetch
	printf '\n'
}

# Step 2: the agents themselves — folder discovery over ENABLED_AGENTS.
# Each folder's install.sh defines install_agent_<name_with_underscores>;
# run_agent_hook maps the folder name and tolerates folders that have not
# landed yet (WARN, not failure).
install_step_tool() {
	local agent
	for agent in ${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}; do
		info "Agent: $agent"
		run_agent_hook install "$agent"
	done
	printf '\n'
}

# Step 3 (right before the completion summary): surface everything the run
# collected along the way — one broken agent never aborts the install, its
# failure lands in AGENT_FAILURES and is reported here, at the end.
install_step_after() {
	local f
	if [ "${#AGENT_FAILURES[@]}" -gt 0 ]; then
		SUMMARY_LINES+=("" "${BOLD}Collected failures (fix them, then re-run):${NC}")
		for f in ${AGENT_FAILURES[@]+"${AGENT_FAILURES[@]}"}; do
			SUMMARY_LINES+=("  ${RED}FAILED:${NC} $f")
		done
	fi
}

# ──────────────────────── completion summary ────────────────────────
# Consumed by the framework's finish_install: where the local state lives,
# one status line per enabled agent (resident-service commands use the real
# unit names from qwen-code/service/ and openclaw/service/), and the two
# follow-up hints (secrets source line + update path).
# shellcheck disable=SC2034  # consumed by the framework's finish_install
SUMMARY_LINES=(
	"  Secrets:  ${CYAN}${SECRETS_FILE#"$HOME"/}${NC} (fill by hand, or re-run with the variables exported)"
	"  Config:   ${CYAN}${AGENT_HOME#"$HOME"/}/${NC} (rendered configs)"
)

_summary_darwin=0
if [ "$(uname -s)" = "Darwin" ]; then _summary_darwin=1; fi
_summary_uid=$(id -u 2>/dev/null || true)
for _summary_agent in ${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}; do
	case "$_summary_agent" in
	opencode)
		SUMMARY_LINES+=("  OpenCode: ${CYAN}~/.config/opencode/opencode.json${NC} → ${AGENT_HOME#"$HOME"/}/opencode/opencode.json")
		;;
	dsh)
		SUMMARY_LINES+=("  DSH:      ${CYAN}~/.dsh/profiles/web/cordis.patch.yml${NC} (web profile, plugins from dsh/plugins.txt)")
		;;
	qwen-code)
		if [ "$_summary_darwin" -eq 1 ]; then
			SUMMARY_LINES+=("  Qwen:     ${CYAN}launchctl print gui/$_summary_uid/com.qwenlm.qwen-serve${NC}")
		else
			SUMMARY_LINES+=("  Qwen:     ${CYAN}systemctl --user status qwen-serve.service${NC}")
		fi
		;;
	openclaw)
		if [ "$_summary_darwin" -eq 1 ]; then
			SUMMARY_LINES+=("  OpenClaw: ${CYAN}launchctl print gui/$_summary_uid/com.openclaw.gateway${NC}")
		else
			SUMMARY_LINES+=("  OpenClaw: ${CYAN}systemctl --user status openclaw-gateway.service${NC}")
		fi
		;;
	esac
done
SUMMARY_LINES+=(
	""
	"  Shell:    ${CYAN}exec zsh${NC} — pick up the agent.env source block (and new PATHs)"
	"  Update:   ${CYAN}cd $INSTALL_DIR && git pull${NC}, then re-run this installer"
)

install_main "$@"
