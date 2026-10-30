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
# values, and clones into the very directory clone_monkey_project would
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
			echo "monkey-scripts missing from $_monkey_dir (no scripts/ subtree)." >&2
			echo "  git -C $_monkey_dir pull    # outdated checkout — or the repo never added the subtree" >&2
			exit 1
		fi
		_monkey_scripts="$_monkey_dir/scripts"
	else
		# curl|bash or a .git-less directory: the only path to a
		# same-revision scripts/ is the INSTALL_DIR checkout.
		# clone_monkey_project cannot do this job — it lives in the very
		# scripts/ being fetched. INSTALL_DIR is where the framework's clone
		# step would have put the checkout too, so that step only confirms it.
		if [ -d "$INSTALL_DIR/.git" ]; then
			# An install already lives here: update it, then run that one.
			git -C "$INSTALL_DIR" pull --ff-only || true
		elif [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR")" ]; then
			# git clone would refuse too, so say why in our own words.
			echo "$INSTALL_DIR is not empty and is not a git clone." >&2
			echo "  move it aside, delete it, or set INSTALL_DIR elsewhere." >&2
			exit 1
		else
			# Fresh clone — the ONLY sub-branch where git is hard-required:
			# the pull sub-branch above degrades gracefully without it, and
			# a zip/tarball must not fail here just for a missing git.
			if ! command -v git >/dev/null 2>&1; then
				echo "git is required to clone $PROJECT — install it first (e.g. sudo apt-get install git), then re-run." >&2
				exit 1
			fi
			# No retry() available yet — the framework loads only after this
			# clone succeeds — so inline the standard 3 attempts. A failed
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
# Shared agent helpers (secrets.env, template rendering, links) — sourced
# after the framework so the output helpers exist. Agent folders are
# resolved against the checkout this file lives in (AGENT_REPO_ROOT).
. "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/agent.sh"

usage() {
	cat <<EOF
Usage: $0 [--with-opencode] [--with-dsh] [--with-qwen-code] [--with-openclaw]

By default all supported agents are installed. Pass one or more --with-
flags to install only the named agents.
EOF
}

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
		echo "Unknown option: ${_AGENT_REST[0]}" >&2
		usage >&2
		exit 2
		;;
	esac
fi
resolve_enabled_agents

# ──────────────────────── project steps ────────────────────────

# Step 1: the shared local-state scaffolding, agent-independent:
# ~/.config/agent/, secrets.env (written with or without values — the
# install never blocks on a missing secret), and the .zshrc source line.
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
	local a generated=""
	for a in ${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}; do
		case "$a" in
		qwen-code)
			if [ -z "$(secret QWEN_SERVER_TOKEN 2>/dev/null)" ] && have_native_cmd openssl; then
				export QWEN_SERVER_TOKEN="$(openssl rand -hex 32)"
				generated="$generated QWEN_SERVER_TOKEN"
			fi
			;;
		openclaw)
			if [ -z "$(secret OPENCLAW_GATEWAY_TOKEN 2>/dev/null)" ] && have_native_cmd openssl; then
				export OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
				generated="$generated OPENCLAW_GATEWAY_TOKEN"
			fi
			;;
		esac
	done
	if [ -n "$generated" ]; then
		info "Auto-generated daemon tokens:$generated (openssl rand -hex 32; rotate by hand in ${SECRETS_FILE#"$HOME"/})."
	fi
	# NO_PROXY default: the template's value only seeds a FRESH file; an
	# existing file missing the key would otherwise fill from the (unset)
	# environment and render empty — and an empty NO_PROXY with a proxy set
	# pushes even loopback traffic (the gateway's own WS/UI binds) through
	# the proxy.
	export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1}"
	write_secrets_template \
		LLM_API_KEY LLM_BASE_URL LLM_MODEL \
		OPENCODE_LLM_API_KEY OPENCODE_LLM_BASE_URL OPENCODE_LLM_MODEL \
		DSH_LLM_API_KEY DSH_LLM_BASE_URL DSH_LLM_MODEL \
		QWEN_LLM_API_KEY QWEN_LLM_BASE_URL QWEN_LLM_MODEL \
		QWEN_DINGTALK_ACCESS_TOKEN QWEN_DINGTALK_SECRET QWEN_SERVER_TOKEN \
		QWEN_QQ_APP_ID QWEN_QQ_APP_SECRET \
		OPENCLAW_LLM_API_KEY OPENCLAW_LLM_BASE_URL OPENCLAW_LLM_MODEL \
		OPENCLAW_DINGTALK_ACCESS_TOKEN OPENCLAW_DINGTALK_SECRET \
		OPENCLAW_QQ_APP_ID OPENCLAW_QQ_CLIENT_SECRET OPENCLAW_QQ_ALLOW_FROM \
		HTTPS_PROXY HTTP_PROXY NO_PROXY OPENCLAW_GATEWAY_TOKEN
	wire_secrets_profile
}

install_step_prepare() {
	ensure_git
	install_shared_secrets
	echo ""
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
	echo ""
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
	"  Config:   ${CYAN}${AGENT_HOME#"$HOME"/}/${NC} (rendered configs + secrets.env)"
)

_summary_darwin=0
if [ "$(uname -s)" = "Darwin" ]; then _summary_darwin=1; fi
_summary_uid=$(id -u 2>/dev/null || true)
for _summary_agent in ${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}; do
	case "$_summary_agent" in
	opencode)
		SUMMARY_LINES+=("  OpenCode: ${CYAN}~/.config/opencode/opencode.json${NC} → ${AGENT_HOME#"$HOME"/}/opencode.json")
		;;
	dsh)
		SUMMARY_LINES+=("  DSH:      ${CYAN}~/.dsh/profiles/web/cordis.patch.yml${NC} (web profile + 4 plugins)")
		;;
	qwen-code)
		if [ "$(uname -s)" = "Darwin" ]; then
			SUMMARY_LINES+=("  Qwen:     ${CYAN}launchctl print gui/$(id -u)/com.qwenlm.qwen-serve${NC}")
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
	"  Shell:    ${CYAN}exec zsh${NC} — pick up the secrets.env source block (and new PATHs)"
	"  Update:   ${CYAN}cd $INSTALL_DIR && git pull${NC}, then re-run this installer"
)

install_main "$@"
