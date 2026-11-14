# monkey-agent

One command sets up the AI agent workstation on a new machine: four
deeply supported agents, their configs rendered from in-repo templates,
and all machine-local values (keys, endpoints, model ids) collected in a
single 0600 file outside the checkout.

| Agent         | Form                                    | Role                                                                                                                        |
| ------------- | --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **OpenCode**  | terminal coding agent                   | daily driver                                                                                                                |
| **DSH**       | web-UI coding agent                     | interactive coding (web profile only)                                                                                       |
| **Qwen Code** | terminal coding agent + resident daemon | executes coding tasks dispatched remotely; dingtalk + QQ Bot channels hosted by its serve daemon                            |
| **OpenClaw**  | resident personal-assistant gateway     | non-coding remote dispatch: gateway daemon (dingtalk + QQ Bot plugins), scheduled wake-ups, hands coding tasks to Qwen Code |

MCP servers and skills are deliberately NOT pre-installed — add them by
hand when a real need shows up.

## Features

- **One command, four agents**: every agent's binary, plugins, rendered
  config and (where applicable) resident service in a single idempotent
  run — re-running never clobbers hand-edited values in agent.env, and it
  never blocks on a missing secret: every enabled agent's config renders
  whether or not its keys are present, ready to be filled in later.
- **Structure in git, values local**: config templates carry the
  structure (model catalogs, channel members, optional keys) as gomplate
  `{{ .Env.NAME }}` references and `{{ range }}`/`{{ if }}` blocks; base
  URLs, model ids and per-model limits are rendered into
  `~/.config/agent/` at install time and never enter the checkout. Secret
  values are never among them — a config carries the variable NAME and
  the value stays in agent.env. Templates may also carry literal
  `${VAR}` / `$VAR` by-name references — the render only ever touches its
  own `{{ }}` syntax, so runtime indirection survives untouched.
- **Resident services**: Qwen Code's serve daemon (loopback API + the
  DingTalk/QQ channels via `serve --channel`) and OpenClaw's gateway
  register as systemd user services (Linux) or launchd agents (macOS),
  with linger best-effort so they survive logout and reboots. The unit
  always renders; enabling it (Linux) or bootstrapping it (macOS) is
  gated on agent.env being non-empty, because a daemon without its
  credential env file crash-loops under `Restart=on-failure`.
- **Health checks**: `./checkhealth.sh` verifies binaries, Node floors,
  secrets presence, LLM connectivity and the resident services — each
  agent folder registers its own sections.

## Requirements

- Linux or macOS; bash 3.2+, curl, git; python3 (health probes).
  gomplate (config template rendering) needs no manual install. Two places
  provision it: `install.sh` asks the chain for it in its prepare step, before
  any agent renders (the framework's dependency pass runs later, so a host that
  never had gomplate would otherwise fail every render and still finish green);
  and the required-tools spec declares `pkg,brew:gomplate` at a `ver:5.3`
  floor for the dependency pass and re-runs. Either way the distro package
  is taken where one ships it (arch's AUR) and Homebrew elsewhere,
  bootstrapping Homebrew on a host that has none.
- Node.js: DSH and Qwen Code need **22+**; OpenClaw needs **26.12+**.
  OpenCode asserts no floor — `opencode-ai` ships its own runtime, and the
  npm lane only self-heals node/npm existence.
  Provisioning goes through the framework's `ensure_node_at_least`:
  distro packages when new enough, Homebrew (which ships a current node on
  every platform, no sudo needed) when the distro index is too old — a
  WARN + skip of that agent when neither route works.
- Linux resident services need a working **systemd user session**
  (absent on WSL/containers — registration is skipped with a WARN, see
  Troubleshooting). macOS uses launchd.
- sudo access for system package installs — the run pre-authorizes it once and
  installs a temporary NOPASSWD drop-in (removed on exit). Global npm installs
  need no sudo at all: `npm_install_g` re-points the prefix to
  `~/.npm-global` when the current one is not user-owned (or is Homebrew's).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/QMonkey/monkey-agent/master/install.sh | bash 2>&1 | tee monkey-agent-install.log
```

Or from a checkout:

```bash
./install.sh                      # all four agents
./install.sh --with-opencode      # only OpenCode
./install.sh --with-dsh           # only DSH
./install.sh --with-qwen-code     # only Qwen Code
./install.sh --with-openclaw      # only OpenClaw
```

Flags combine (`--with-dsh --with-openclaw`); any other option is a usage
error (exit 2). The same flags select agents for `checkhealth.sh` too.
A failing agent never aborts the run: each failure is collected
and listed at the end under `Collected failures`, and the fix is to repair
the cause and re-run. The checkout the installer clones/updates is
`$INSTALL_DIR` (default `~/Documents/monkey-agent`).

## Secrets: export before installing (optional)

All machine-local values live in `~/.config/env/agent.env` (0600,
gitignored, never committed). Export variables before the first install,
or edit the file afterwards — existing file values always win over the
environment on a re-run, so daily key rotation is a plain file edit.

```bash
export LLM_API_KEY="..."
export LLM_BASE_URL="..."
export LLM_MODEL="..."
# then run the installer
```

The full variable set:

| Layer                                        | Variables                                                                     | Notes                                                                                                                                                                                                                                  |
| -------------------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shared LLM backend (default for every agent) | `LLM_API_KEY` / `LLM_BASE_URL` / `LLM_MODEL`                                  | the only three needed with a single backend                                                                                                                                                                                            |
| Shared model catalog (optional)              | `LLM_MODELS`                                                                  | comma-separated extra models offered to every agent; see **Model catalog** below                                                                                                                                                       |
| Daemon egress proxy (optional)               | `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`                                     | filled from the installer's environment; `NO_PROXY` must keep the loopback binds off the proxy (the installer merges `localhost,127.0.0.1,::1` into what it fills; checkhealth reports a file that lacks a loopback bind as a failure) |
| OpenCode overrides                           | `OPENCODE_LLM_API_KEY` / `_BASE_URL` / `_MODEL`                               | optional, per-field                                                                                                                                                                                                                    |
| DSH overrides                                | `DSH_LLM_API_KEY` / `_BASE_URL` / `_MODEL`                                    | optional, per-field                                                                                                                                                                                                                    |
| Qwen Code overrides                          | `QWEN_LLM_API_KEY` / `_BASE_URL` / `_MODEL`                                   | optional, per-field                                                                                                                                                                                                                    |
| Qwen Code dingtalk channel                   | `QWEN_DINGTALK_ACCESS_TOKEN` / `QWEN_DINGTALK_SECRET`                         | AppKey / AppSecret of a Stream-Mode bot                                                                                                                                                                                                |
| Qwen Code QQ Bot channel                     | `QWEN_QQ_APP_ID` / `QWEN_QQ_APP_SECRET`                                       | QQ Bot Open Platform (q.qq.com); empty → QR-code login on the channel's first start                                                                                                                                                    |
| OpenClaw overrides                           | `OPENCLAW_LLM_API_KEY` / `_BASE_URL` / `_MODEL`                               | optional, per-field                                                                                                                                                                                                                    |
| OpenClaw dingtalk channel                    | `OPENCLAW_DINGTALK_ACCESS_TOKEN` / `OPENCLAW_DINGTALK_SECRET`                 | an independent dingtalk app — never shared with the Qwen Code one                                                                                                                                                                      |
| OpenClaw QQ Bot channel                      | `OPENCLAW_QQ_APP_ID` / `OPENCLAW_QQ_CLIENT_SECRET` / `OPENCLAW_QQ_ALLOW_FROM` | rendered as `${VAR}` config references; the allowlist is required by the qqbot channel (comma-separated sender ids, no wildcards, and the channel is not rendered without it); an independent QQ bot — never shared with Qwen's        |
| Qwen serve daemon (auto-generated)           | `QWEN_SERVER_TOKEN`                                                           | auto-generated at install (`openssl rand -hex 32`) → `--require-auth`; a hand-set value wins; emptying it by hand → token-less loopback (warned)                                                                                       |
| OpenClaw gateway (auto-generated)            | `OPENCLAW_GATEWAY_TOKEN`                                                      | same posture for the gateway control plane (dashboard + agent API) on 127.0.0.1:18790                                                                                                                                                  |

### Model catalog (`LLM_MODELS`)

`LLM_MODEL` is the primary model. `LLM_MODELS` (optional, comma-separated)
adds further models to every agent's provider list: the primary is hoisted to
the front, the rest follow in listed order, duplicates and stray whitespace
are dropped. Each entry is resolved against the cached
[models.dev](https://models.dev/api.json) catalog at install time, so the
rendered configs carry each model's own limits and reasoning tier as far
as that agent's schema has the fields (Qwen Code takes the context window
and one effort tier only):

- an unknown or limit-less model falls back to a conservative
  `128000 / 32768` with no effort option — undershooting only costs earlier
  compaction, overshooting can make every request fail;
- a reasoning tier is configured only when the model declares one (`high`,
  else `xhigh`), because sending an effort a model does not list risks a 400
  on the first request;
- the catalog is fetched once per installer run and never cached on disk, so
  re-running the installer is how a model's published limits get picked up.

There is no per-agent `*_LLM_MODELS`: the catalog is shared, while the
override layers above stay per-field.

`checkhealth.sh` compares the model count each rendered config actually
carries with the count agent.env asks for and warns when they differ —
the signature of a catalog that was unreachable during the install (or of
an agent.env edit that has not been rendered yet). Re-run the installer to
sync.

Notes:

- **Only secrets need exporting**: an unset _secret_ never blocks the
  install — the hooks export the resolved value (empty included), so every
  agent's config renders and checkhealth's presence + connectivity sections
  tell you what to fill. That is different from a template _reference_ that
  nothing exports: that fails the one render loudly (names reported, no
  file written) and the run continues with the other agents, because a
  silently empty value once crash-looped a daemon. No public endpoint/model
  defaults are baked in.
- The two daemon tokens are auto-generated by install.sh's shared
  secrets step (only when empty; gated on the agent being enabled) and
  persisted in agent.env — the single source of truth; re-runs never
  rotate them behind your back.
- Override layers are per-field: an unset `OPENCODE_LLM_MODEL` falls
  back to the shared `LLM_MODEL`, so overriding one field never requires
  writing the full triple.
- `agent.env.template` documents the full variable set, grouped per
  agent — it is also the seed template the installer renders the real
  file from.
- The installer appends one marker-guarded block (`# [normal] agent secrets
(remove these two lines to disable)`) to your login profile — `~/.zprofile`
  for zsh, `~/.bash_profile`/`~/.profile` plus `~/.bashrc` for bash — sourcing
  agent.env with `set -a` so the values land in the environment of every login
  shell. `normal` is the framework's default partition class, shared with the
  other projects' env blocks; the partition still sorts the block ahead of the
  exec-style autostart blocks (`tail`) no matter which installer ran last.
  Remove the block and its marker line to disable.

## What gets installed

### OpenCode

- Binary via npm (`npm install -g opencode-ai` — the same lane as every
  other agent, one upgrade path); the official script
  (`curl -fsSL https://opencode.ai/install | bash`) is the fallback for
  hosts without node/npm. Skipped when already present.
- Config rendered to `~/.config/agent/opencode/opencode.json` and
  symlinked from `~/.config/opencode/opencode.json`.
- Plugins: superpowers only — the tmux-scout plugin and its OpenCode-side
  registration are owned by the tmux setup (done at tmux startup), not
  this repo.
- The API key is never rendered as a value: the config references it
  with OpenCode's native `{env:NAME}` syntax — the NAME is resolved at
  render time (the `OPENCODE_LLM_API_KEY` override when set, else the
  shared `LLM_API_KEY`).

### DSH (web profile only)

- Node.js 22+ / npm auto-installed when missing, then `npm install -g
@deepseek-ai/dsh`; pnpm is auto-installed for plugin management.
- Four web-profile plugins (`dsh plugin --profile web add`), listed in
  `dsh/plugins.txt`: `@zhengjunyao/dsh-updater` (release tracking,
  one-click update with automatic rollback), `dsh-permission-rules`
  (declarative permission rules), `dsh-at-file` (Codex-style `@file`
  mentions), `dsh-notify-me` (desktop notifications on completion /
  needs-input / approval). Already-installed plugins are skipped; plugin
  bundles activate on the next `dsh web` start.
- Config rendered to `~/.config/agent/dsh/cordis.patch.yml` and
  symlinked to `~/.dsh/profiles/web/cordis.patch.yml` (dsh re-reads the
  patch per request — no restart needed for config edits).
- The API key renders as a variable NAME (`apiKeyEnv` indirection);
  base URL and model render as empty fields until agent.env provides
  them (no public defaults).
- `checkhealth.sh` runs a web-profile smoke test: it starts `dsh web
--no-open`, sleeps a fixed 30s (no early exit), then greps the captured log
  for the `:3080` startup banner and shuts the process down (SIGTERM, 5s
  grace, SIGKILL, `wait` reaps). Before that it pre-checks the port with
  `lsof` — a listener already on `:3080` means the profile is up and the
  smoke would fail its own bind into a false "no banner" report, so it
  reports that instead. `lsof` is declared as an **optional** tool (its
  absence never fails the dependency side of the run); the probe asks the
  chain for it via `install_pkg`, which only succeeds in `--install`
  mode — a plain run without `lsof` skips the pre-check and starts the
  server anyway. A smoke that finds no banner returns non-zero from the
  dsh hook, so it lands in `Collected failures` and makes `checkhealth.sh`
  exit 1.

### Qwen Code

- Node.js 22+ / npm auto-installed (via the framework's node provisioning),
  then `npm install -g @qwen-code/qwen-code` (bin: `qwen`).
- `~/.qwen/settings.json` (symlinked from
  `~/.config/agent/qwen/settings.json`) — provider, model, and the
  dingtalk + QQ Bot channels inlined; credentials render as `$VAR` name
  references.
- ONE resident service: `qwen-serve.service` — `qwen serve --channel`
  hosts the loopback HTTP/Web Shell API (127.0.0.1:4170) AND both
  channel adapters in a single daemon. The unit passes `--channel all`
  only when at least one channel's credentials resolve — with none the
  flag is omitted and the config renders `"channels": {}`, because a
  `--channel` request with nothing to run is the failure mode. Install
  re-checks that the flag and the rendered `channels` map agree, and
  records a failure when they drift. Status:
  `systemctl --user status qwen-serve.service` (macOS launchd label
  `com.qwenlm.qwen-serve`). Linger is enabled best-effort.
- Credentials come from the shared agent.env — on Linux the unit's
  `EnvironmentFile=`, on macOS the plist sources the same file in its
  `ProgramArguments` (launchd has no EnvironmentFile). So a shell export
  is enough for the interactive TUI and a file edit +
  `systemctl --user restart` covers the daemon.
- `QWEN_SERVER_TOKEN` is auto-generated at install (openssl rand -hex
  32, persisted in agent.env) — the daemon boots with
  `--require-auth`; emptying the variable by hand reverts to token-less
  on loopback (warned).
- QQ Bot: with `QWEN_QQ_APP_ID` / `QWEN_QQ_APP_SECRET` set, the channel
  connects with them; empty, the channel falls back to QR-code login on
  first start.

### OpenClaw

- Node.js 26.12+ floor (higher than the other agents) via the
  framework's node provisioning (Homebrew covers hosts whose distro
  index is too old), then `npm install -g openclaw@latest`
  (`--allow-scripts=openclaw@latest` — npm >= 11.19 gates install scripts
  behind that allow-list, and the value `npm_install_g` passes is the
  whole spec list it was handed, comma-joined, not a package name),
  falling back to the official installer script.
- Two official channel plugins are installed
  (`openclaw plugins install`): `@dingtalk-real-ai/dingtalk-connector`
  and `@tencent-connect/openclaw-qqbot` — neither is a core OpenClaw
  channel. Upstream gates an npm-sourced plugin behind two interactive
  prompts (provenance, then capability consent) and defaults a bare spec
  to ClawHub, so the installer runs it non-interactively with
  `openclaw plugins install "npm:$spec" --force --accept-capabilities --pin`
  — the specs above are pinned constants in this repo whose manifests were
  reviewed at adoption, and a retried child cannot read the tty. `--pin`
  records the resolved exact version. A re-run whose
  `openclaw plugins list` already shows the plugin short-circuits. If the
  command still fails, the step warns with that exact command for a manual
  review — and treats the agent as a degraded success (nothing collected
  as a failure): the config renders WITHOUT that channel member, because
  the strict schema rejects a channel key whose plugin is not installed
  and the Gateway would refuse to start.
- Config rendered to `~/.config/agent/openclaw/openclaw.json` and
  installed as a **regular file copy** at `~/.openclaw/openclaw.json` —
  deliberately NOT a symlink: upstream replaces the config atomically
  and warns against symlinked layouts. Re-running the installer
  re-renders and overwrites hand edits (the template is the structural
  truth).
- Credentials: the single `~/.config/env/agent.env` (0600) — the gateway
  reads it via the unit's `EnvironmentFile=` (the macOS plist sources the
  same file in its command line, and the Gateway also auto-loads it as its
  documented global env fallback); the config references variables BY NAME.
- The gateway runs as a resident service: `openclaw-gateway.service`
  (macOS launchd label `com.openclaw.gateway`), loopback
  `127.0.0.1:18790`, with the cron engine (scheduled wake-ups) enabled.
  `OPENCLAW_GATEWAY_TOKEN` is auto-generated at install (persisted in
  agent.env) — the gateway boots with token auth; emptying it by hand
  reverts to token-less on loopback (warned). The QQ Bot channel's
  credentials live in agent.env (`OPENCLAW_QQ_APP_ID` /
  `OPENCLAW_QQ_CLIENT_SECRET` + the required allowlist
  `OPENCLAW_QQ_ALLOW_FROM`) and render as `${VAR}` config references.

### Removing the resident services

```bash
systemctl --user disable --now openclaw-gateway.service qwen-serve.service
rm ~/.config/systemd/user/openclaw-gateway.service ~/.config/systemd/user/qwen-serve.service
systemctl --user daemon-reload
```

macOS: `launchctl bootout gui/$(id -u)/com.openclaw.gateway` and
`launchctl bootout gui/$(id -u)/com.qwenlm.qwen-serve`, then remove the
matching plists from `~/Library/LaunchAgents/`.

## Configs: structure in git, values local

Each agent folder in this repo is self-contained: config templates
(gomplate `{{ .Env.NAME }}` references), plugin lists, service units. The
installer renders the templates with gomplate (references only, no
format awareness) and writes the result atomically with 0600
permissions into `~/.config/agent/` — base
URLs, model ids and per-model limits exist only there, never in the
checkout, and secret values never appear in a rendered file at all.
`~/.config/opencode/opencode.json`
and friends are symlinks into that directory; rendered files are
regenerated on every install, so hand-edits to a rendered file get
overwritten — change the template or the secrets file instead.

No secret value ever lands in a rendered config: every agent renders a
variable NAME reference (`{env:NAME}` / `apiKeyEnv` / `"$VAR"` /
`${VAR}`) and the value reaches the process through the environment
(agent.env, sourced with `set -a`). The fill mode (render's
`fill KEY...`) is the value-merging path: it backfills empty `KEY=`
lines from the environment while preserving hand-edited values —
agent.env itself is rendered this way (seeded from
agent.env.template).

When the installer must replace a foreign config file (the `takeover`
link mode), it first moves the original to `<file>.link-bak`. Block
ordering in the login profile is the framework's head/normal/tail
stable partition — the secrets block (head) always lands before the
exec-style autostart blocks (tail), regardless of install order.

## Check health

```bash
./checkhealth.sh                      # report every enabled agent
./checkhealth.sh --install            # report first, then install what is missing
./checkhealth.sh --with-openclaw      # only the named agents' sections
```

`-i` is the short form of `--install`, `-h`/`--help` prints the usage, and
the `--with-*` flags are the same roster as `install.sh`'s (anything else
is a usage error, exit 2). `--skip-check-config` skips the framework's
config-file section — `install.sh` passes it because the links are made
after that step; manual runs have no reason to. A manual `--install`
authenticates sudo once and rides the sudo timestamp; export
`SUDO_DROPIN=1` to install the run-scoped NOPASSWD drop-in the way
`install.sh` does by default.

Four kinds of checks (three-state `[ OK ] / [WARN] / [FAIL]` output):

1. **Tool health** — the required tools (gomplate at a `ver:5.3` floor,
   python3) and the shared `node` floor (`ver:22`), then per agent: its
   binary + parsable version, its own Node floor where it has one
   (dsh/qwen 22+, openclaw 26.12+), and DSH's web-profile smoke. The four
   agent binaries are additionally listed under an **Agents** section as
   optional tools — a missing one prints `[FAIL]` there but is not a
   dependency failure; the hook above is what reports it.
2. **Secrets health** — every enabled agent's resolved LLM triple
   (key, base URL + model) through its override layer, the channel
   credential pairs and the two daemon tokens, all names only, never
   values, plus the `NO_PROXY` loopback floor the resident daemons need
   in agent.env. agent.env itself is not stat'd — no presence or
   permission probe; a missing file simply reads as empty variables.
3. **Connectivity** — a minimal authenticated request (`GET {baseURL}/models`,
   ~10s timeout, the key handed to curl through a 0600 temp file). The base
   URL resolves from agent.env first, falling back to the agent's rendered
   config only when nothing exports it; with neither the probe prints an
   info line and skips. Export `SKIP_CONNECTIVITY=1` to skip
   on offline machines.
4. **Resident process health** — the gateway / serve service state,
   `openclaw gateway status`, the serve daemon's loopback health endpoint
   (probed only while the service is active), and the channels'
   outbound reachability (api.dingtalk.com / api.sgroup.qq.com route
   probes, credential-gated) — all WARN-level and never counted.

Exit code: **1** when a required tool or the shared node floor is missing,
or when anything landed in the collected-failure list — a broken or
failing agent hook (missing binary, Node below its floor, failed DSH
smoke), a failed connectivity probe, a `NO_PROXY` without a loopback bind,
or an agent whose rendered `channels` map disagrees with the unit's
`--channel all`. **0** otherwise, WARNs included. The service/channel
probes in section 4 are the strictly advisory ones.

Agent folders register their own sections; `--install` installs missing
dependencies. Run it after installing to see what is missing. The four
categories above are the content, not four printed headers: the framework
prints Platform / node / Required tools / Agents, then every enabled
agent's hook lines follow in one block without their own header, and the
summary closes the run.

## Troubleshooting

- **"No systemd user session" (WSL / containers)**: resident service
  registration is skipped with a WARN — the unit files still land under
  `~/.config/systemd/user/`, and checkhealth reports the service state
  as unknown. Run on a host with a systemd user session, or start the
  processes by hand.
- **Channel credentials unresolved**: the rendered configs carry the
  variable names, so an empty agent.env leaves the channels
  disconnected. Fill the dingtalk pairs (`QWEN_DINGTALK_*` and
  `OPENCLAW_DINGTALK_*` — two independent dingtalk apps; Stream Mode
  enabled in the developer portal) and the QQ pairs (`QWEN_QQ_*` or
  leave empty for QR-code login; `OPENCLAW_QQ_APP_ID` / `OPENCLAW_QQ_CLIENT_SECRET`
  for OpenClaw — from the QQ Bot Open Platform, q.qq.com), then re-run.
  After a credentials change restart the daemons:
  `systemctl --user restart qwen-serve.service openclaw-gateway.service`.
- **Connectivity failures in checkhealth**: a failed `GET {baseURL}/models`
  is collected as an agent failure, so `checkhealth.sh` exits 1 and the
  installer's dependency pass retries it and ends with a WARN
  (`Some dependencies could not be installed automatically`) — the install
  itself still runs to completion and no agent is aborted. Fix the key /
  base URL / network, then re-run. Offline machines:
  `export SKIP_CONNECTIVITY=1`.
- **Binary installed but "not on this shell's PATH"**: the installer
  cannot modify the running shell — open a new shell (or `exec zsh`).
- **dsh plugins not active**: plugin bundles load on the next `dsh web`
  start — restart the web profile if it is running.
- **Hand-edited rendered config got overwritten**: by design — the
  template is the structural truth. Change the template, or put the
  value in agent.env.

## Layout

```text
install.sh            one-shot installer (agent selection via --with-*)
checkhealth.sh        dependency + health check
lib/agent.sh          shared helpers: secrets resolution, credential fill,
                      block wiring, the agent roster (ALL_AGENTS) and the
                      scaffolding every agent reuses (Node floor, npm install
                      lane, credential pair, resident-service registration) —
                      rendering lives in the framework:
                      scripts/lib/template.sh
agent.env.template    the full local-values variable set, grouped per agent
<agent>/              one folder per agent — templates and agent-specific
                      files only; each defines install_agent_<name>() /
                      checkhealth_agent_<name>() for the entry points to
                      call (<name> = the folder name with `-` mapped to
                      `_`, so qwen-code/ defines install_agent_qwen_code)
scripts/              shared installer/check framework (a `git subtree` of
                      github.com/QMonkey/monkey-scripts)
```

Adding an agent means adding one folder plus its name in `ALL_AGENTS`
(`lib/agent.sh`) — the `--with-*` flags, the default enable set and the usage
text all derive from that list, and the framework subtree stays untouched.

Three paths are environment-overridable (`${VAR:-default}` at the top of
the file named after them): `INSTALL_DIR` (`install.sh`, default
`$HOME/Documents/monkey-agent` — the checkout the curl|bash path clones and
runs), `AGENT_HOME` (`lib/agent.sh`, default `$HOME/.config/agent` —
rendered configs) and `SECRETS_FILE` (`lib/agent.sh`, default
`$HOME/.config/env/agent.env` — the values file; the variable kept its old
name when the file moved out of `AGENT_HOME`). Note that the four service
templates reference the agent.env path **literally**
(`EnvironmentFile=`/the plist's source line), so overriding `SECRETS_FILE`
changes only what the installer writes and what the profile sources — the
resident daemons would still read the default path.
