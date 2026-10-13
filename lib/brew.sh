# monkey-scripts/lib/brew.sh — Homebrew: install_pkg's fallback manager and
# the BREW_FIRST lane, plus the installer itself. Sourced by
# lib/bootstrap.sh (both entry points — install_pkg needs the runtime side
# under checkhealth --install too).
#
# NOTE: install_linuxbrew fetches the installer through fetch_url_or_clone
# (lib/clone.sh) — clone.sh therefore also lives in the bootstrap common set.

# ──────────────────────────── Homebrew ────────────────────────────
# Names that should prefer Homebrew over the system package manager: system
# repos ship versions that lag far behind (fzf: 0.44 on Ubuntu noble vs
# current 0.7x). Projects append names here.
BREW_FIRST=()

# The brew-first whitelist: a BREW_FIRST tool installed via brew gets a
# symlink in ~/.local/bin, which export_path seeds at the FRONT of PATH.
# This is what keeps those tools beating the system versions now that brew
# itself sits at the BACK. Idempotent; never replaces anything that is not a
# symlink (a user's own script in ~/.local/bin stays untouched).
_brew_first_link() {
	local p prefix
	prefix="$(brew --prefix 2>/dev/null)" || return 0
	[ -d "$prefix/bin" ] || return 0
	mkdir -p "$HOME/.local/bin" || return 0
	for p in "$@"; do
		[ -x "$prefix/bin/$p" ] || continue
		if [ -e "$HOME/.local/bin/$p" ] && [ ! -L "$HOME/.local/bin/$p" ]; then
			warn "$HOME/.local/bin/$p exists and is not a symlink — not touching it."
			continue
		fi
		ln -sfn "$prefix/bin/$p" "$HOME/.local/bin/$p"
	done
}

probe_brew_name() {
	# `brew info` fails on an unknown formula. Without a brew binary there is
	# nothing to probe against — don't filter.
	have_native_cmd brew || return 0
	brew info "$1" >/dev/null 2>&1
}

# The brew twin of the pacman orphan: retry's timeout kills the brew WRAPPER
# but not its ruby worker, which stays alive holding the cache flock — every
# later brew then refuses with "already locked". Homebrew's locks are flocks
# (release when the holder dies), so killing the orphan IS the unlock.
# Scoped to cmdlines mentioning the brew prefix (a bare `pkill brew` misses
# the ruby worker); only fires after OUR OWN timed-out attempt.
cleanup_timed_out_brew() {
	local prefix
	prefix="$(brew --prefix 2>/dev/null)" || return 0
	pgrep -f "$prefix" >/dev/null 2>&1 || return 0
	warn "killing orphaned brew process(es) left by the timed-out brew (they hold the cache flock)..."
	pkill -f "$prefix" 2>/dev/null
	sleep 1
	return 0 # best-effort — never fail the caller over cleanup
}

# One brew install with the standard retry; a timed-out attempt (rc 124)
# triggers the orphan cleanup so the retry ladder does not hit the same
# lock again. Returns the install's exit code.
brew_install_retry() {
	local t="$1" desc="$2"
	shift 2
	local brc=0
	# Brew can stall two different ways under retry→timeout, whose child
	# sits in a NON-foreground process group — ANY prompt there is frozen
	# by SIGTTIN with input unreachable (^C only reaches the foreground
	# group). Both flags make brew fail fast instead of prompting:
	#   HOMEBREW_NO_INTERACTIVE — stdin-reading formula hooks and the like
	#     (observed on Ubuntu: checkhealth --install hung at brew install
	#     zig's [y/n], ^C/D dead).
	#   HOMEBREW_NO_ASK — brew ≥7 asks "Do you want to proceed with the
	#     installation? [y/n]" whenever the plan includes dependencies and
	#     gates that prompt on the TTY ONLY: the INTERACTIVE flag does NOT
	#     suppress it (observed on CentOS: checkhealth --install froze at
	#     brew install wget2's dependency prompt). Maps to `brew install
	#     --no-ask`.
	# The Homebrew INSTALLER already runs with NONINTERACTIVE=1
	# (install_linuxbrew) — this covers the runtime side.
	retry -t "$t" -s "$desc" env HOMEBREW_NO_INTERACTIVE=1 HOMEBREW_NO_ASK=1 brew install "$@" || brc=$?
	[ "$brc" -eq 124 ] && cleanup_timed_out_brew
	return "$brc"
}

# Does a brew at <prefix> actually run? A half-installed Homebrew
# (portable-ruby unpack failed) leaves bin/brew behind while every
# invocation dies — verify with --version.
brew_functional() {
	[ -x "$1/bin/brew" ] && "$1/bin/brew" --version >/dev/null 2>&1
}

# The portable-ruby unpack needs tar AND gzip (the bottle is a .tar.gz)
ensure_brew_unpack_tools() {
	local tool
	for tool in tar gzip; do
		have_native_cmd "$tool" && continue
		install_pkg "$tool" ||
			warn "$tool is missing — the Homebrew install will likely fail halfway."
	done
}

install_linuxbrew() {
	local brew_prefix="" cand
	if have_native_cmd brew; then
		brew_prefix="$(dirname "$(dirname "$(command -v brew)")")"
		ok "Homebrew already installed at $brew_prefix."
	else
		# brew may exist at a standard prefix without being on PATH — an
		# earlier monkey-* component installed it and this process did not
		# inherit the profile. Adopt it instead of re-downloading. The
		# candidate prefixes come from BREW_PREFIXES (env.sh) — the single
		# source of truth the brew PATH tier derives from too.
		for cand in $BREW_PREFIXES; do
			if [ -x "$cand/bin/brew" ]; then
				brew_prefix="$cand"
				ok "Homebrew found at $brew_prefix (not on PATH — adopting)."
				break
			fi
		done
	fi
	if [ -z "$brew_prefix" ]; then
		info "Installing Homebrew/Linuxbrew..."
		# The temporary NOPASSWD drop-in makes the timestamp irrelevant, so
		# the official installer runs unmodified. Download fully before
		# executing: `curl | bash` would run a truncated script.
		local installer="/tmp/homebrew_install.$$.sh"
		# `curl -fsSL -o` is silent: on a slow network the download would
		# look like a hang.
		info "Downloading the Homebrew installer..."
		ensure_brew_unpack_tools
		if fetch_url_or_clone "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh" "https://github.com/Homebrew/install" "$installer" "Homebrew installer"; then
			:
		else
			warn "Homebrew installer download failed — continuing without Homebrew."
			return 0
		fi
		NONINTERACTIVE=1 /bin/bash "$installer" ||
			warn "Homebrew installer failed — continuing without Homebrew."
		rm -f "$installer"

		for cand in $BREW_PREFIXES; do
			if [ -x "$cand/bin/brew" ]; then
				brew_prefix="$cand"
				break
			fi
		done
	fi

	if [ -n "$brew_prefix" ] && brew_functional "$brew_prefix"; then
		# Brew goes AFTER system paths but BEFORE the WSL-injected Windows
		# section (the opposite of `brew shellenv` on both ends): prepending
		# let brew's python@3.x shadow /usr/bin/python3, plain-appending put
		# brew behind the /mnt/* shims so `npm` resolved to the Windows one.
		# export_path_pre_win splits the difference: system > brew > Windows.
		export_path_pre_win "$brew_prefix/bin" "$brew_prefix/sbin"
		ok "Homebrew/Linuxbrew ready at $brew_prefix (before Windows shims, after system paths)."
		# Persist the same insert for future shells. Idempotent.
		persist_brew_path "$brew_prefix"
	else
		# Two flavors of "no usable brew": never installed, or dead (bin/brew
		# present, vendor ruby missing) — name the difference.
		if [ -n "$brew_prefix" ]; then
			warn "brew exists at $brew_prefix but cannot run (incomplete install?) — continuing without Homebrew. Fix: reinstall Homebrew."
		else
			warn "brew not found — continuing without Homebrew."
		fi
	fi
}
