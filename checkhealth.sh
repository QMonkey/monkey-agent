#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# agent dependency check
#
# The check framework lives in scripts/ (a `git subtree` of
# github.com/QMonkey/monkey-scripts) — this file only declares WHAT to check.
# ──────────────────────────────────────────────────────────────

. "$(dirname "${BASH_SOURCE[0]:-$0}")/scripts/checkhealth.sh" || {
	echo "monkey-scripts not found — update this checkout (git pull / re-clone)," >&2
	echo "or run install.sh, which bootstraps monkey-scripts itself." >&2
	exit 1
}

# ──────────────────────── identity ────────────────────────
PROJECT=monkey-agent

# Shared agent helpers (secrets.env probing, the agent contract hooks).
. "$(dirname "${BASH_SOURCE[0]:-$0}")/lib/agent.sh"

# ──────────────────────── agent selection ────────────────────────
# Same --with-* flags as install.sh (default: all four); the framework's
# own flags (-i/--install, --skip-check-config, -h/--help) pass through to
# checkhealth_main untouched, anything else is a usage error.
parse_agent_flags "$@"
for _arg in ${_AGENT_REST[@]+"${_AGENT_REST[@]}"}; do
	case "$_arg" in
	-i | --install | --skip-check-config | -h | --help) ;;
	*)
		echo "Unknown option: $_arg" >&2
		exit 2
		;;
	esac
done
resolve_enabled_agents

# ──────────────────────── version gate ────────────────────────
# node: shared runtime floor for dsh / qwen-code / openclaw (opencode ships
# its own binary). Higher per-agent floors (openclaw wants 26.12+) and the
# NodeSource/brew upgrade paths live in the agent install hooks — this spec
# is the distro-package best effort (pkg.sh maps node → nodejs per distro).
MAIN_VERSION="node|ver:22|Node.js (agents' runtime)|pkg"
MAIN_VERSION_TITLE="node"

# ──────────────────────── required ────────────────────────
# @header|Title   bold section title
#   @config         the "Config files" section (not used — rendered configs
#                   live outside the checkout and are covered by the health
#                   hooks, so a fresh machine must not FAIL here)
REQUIRED_CHECKS=(
	"@header|Required tools"
	"envsubst|bin|envsubst (gettext — config template rendering)"
	"python3|bin|python3 (health probes)"
)

# ──────────────────────── optional ────────────────────────
# Agent binaries: report-only (INSTALL_OPTIONAL stays 0 — a missing agent
# is install.sh's job: npm -g plus config rendering, plugins and resident
# services, nothing a package manager one-liner can do).
OPTIONAL_SECTION_TITLE="Agents"
OPTIONAL_SECTION_NOTE="(missing agents are installed by install.sh, not here)"
OPTIONAL_CHECKS=(
	"opencode|bin|opencode (coding agent)"
	"dsh|bin|dsh (DeepSeek Harness, web profile)"
	"qwen|bin|qwen (Qwen Code)"
	"openclaw|bin|openclaw (assistant gateway)"
	"lsof|bin|lsof (dsh web-profile smoke port pre-check)"
)

# ──────────────────────── agents ────────────────────────
# Each agent folder registers its own sections by defining
# checkhealth_agent_<name_with_underscores> in <folder>/checkhealth.sh; this hook
# runs every enabled agent's function. The skeleton tolerates folders that
# have not landed yet (later tasks add them): a missing checkhealth.sh is a
# WARN, never a failure.
checkhealth_extra() {
	local agent
	for agent in ${ENABLED_AGENTS[@]+"${ENABLED_AGENTS[@]}"}; do
		run_agent_hook checkhealth "$agent"
	done
}

# ──────────────────────── summary & exit code ────────────────────────
# The framework's print_summary exits directly, so an "after the summary"
# sweep cannot run past it — override instead. Output and exit status match
# the framework's, plus the collected AGENT_FAILURES list (the mirror of
# install.sh's install_step_after): any collected failure — a broken agent
# hook or a failed connectivity check (spec §4.6) — makes the health run
# exit 1. Failures are still never fatal mid-run: the whole run completes
# first, then everything is reported together here.
print_summary() {
	local f rc=0
	if [ "$REQUIRED_FAILURES" -eq 0 ]; then
		echo -e "${GREEN}${BOLD}All required dependencies satisfied.${NC}"
	else
		echo -e "${RED}${BOLD}Some required dependencies are missing.${NC}"
		if ! $INSTALL_MODE; then
			echo -e "Run ${CYAN}$0 --install${NC} to install them automatically."
		fi
		rc=1
	fi
	if [ "${#AGENT_FAILURES[@]}" -gt 0 ]; then
		echo ""
		echo -e "${BOLD}Collected failures (fix them, then re-run):${NC}"
		for f in ${AGENT_FAILURES[@]+"${AGENT_FAILURES[@]}"}; do
			echo -e "  ${RED}FAILED:${NC} $f"
		done
		rc=1
	fi
	exit "$rc"
}

checkhealth_main ${_AGENT_REST[@]+"${_AGENT_REST[@]}"}
