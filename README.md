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
  run — re-running never clobbers hand-edited values, and it never blocks
  on a missing secret: every enabled agent's config renders whether or
  not its keys are present, ready to be filled in later.
- **Structure in git, values local**: config templates (`$__X__`
  placeholders, rendered by envsubst) are committed; company URLs, model
  ids and keys are rendered into `~/.config/agent/` at install time and
  never enter the checkout. Templates may also carry literal `${VAR}` /
  `$VAR` by-name references — the render only ever touches its own
  `$__X__` form, so runtime indirection survives untouched.
- **Resident services**: Qwen Code's serve daemon (loopback API + the
  DingTalk/QQ channels via `serve --channel`) and OpenClaw's gateway
  register as systemd user services (Linux) or launchd agents (macOS),
  with linger best-effort so they survive logout and reboots.
- **Health checks**: `./checkhealth.sh` verifies binaries, Node floors,
  secrets presence, LLM connectivity and the resident services — each
  agent folder registers its own sections.

## Requirements

- Linux or macOS; bash 3.2+, curl, git; envsubst (gettext — config
  template rendering), python3 (health probes).
- Node.js: DSH and Qwen Code need **22+**; OpenClaw needs **24.16+ /
  26.1+**. Provisioning goes through the framework's `ensure_node_at_least`:
  distro packages when new enough, Homebrew (which ships a current node on
  every platform, no sudo needed) when the distro index is too old — a
  WARN + skip of that agent when neither route works.
- Linux resident services need a working **systemd user session**
  (absent on WSL/containers — registration is skipped with a WARN, see
  Troubleshooting). macOS uses launchd.
- sudo access for system package installs (passwordless sudo is needed
  for OpenClaw's automatic Node upgrade on Linux).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/QMonkey/monkey-agent/master/install.sh | bash
```

Or from a checkout:

```bash
./install.sh                      # all four agents
./install.sh --with-opencode      # only OpenCode
./install.sh --with-dsh           # only DSH
./install.sh --with-qwen-code     # only Qwen Code
./install.sh --with-openclaw      # only OpenClaw
```

## Secrets: export before installing (optional)

All machine-local values live in `~/.config/agent/secrets.env` (0600,
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

| Layer                                        | Variables                                                     | Notes                                                                                                                                            |
| -------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Shared LLM backend (default for every agent) | `LLM_API_KEY` / `LLM_BASE_URL` / `LLM_MODEL`                  | the only three needed with a single backend                                                                                                      |
| OpenCode overrides                           | `OPENCODE_LLM_API_KEY` / `_BASE_URL` / `_MODEL`               | optional, per-field                                                                                                                              |
| DSH overrides                                | `DSH_LLM_API_KEY` / `_BASE_URL` / `_MODEL`                    | optional, per-field                                                                                                                              |
| Qwen Code overrides                          | `QWEN_LLM_API_KEY` / `_BASE_URL` / `_MODEL`                   | optional, per-field                                                                                                                              |
| Qwen Code dingtalk channel                   | `QWEN_DINGTALK_ACCESS_TOKEN` / `QWEN_DINGTALK_SECRET`         | AppKey / AppSecret of a Stream-Mode bot                                                                                                          |
| Qwen Code QQ Bot channel                     | `QWEN_QQ_APP_ID` / `QWEN_QQ_APP_SECRET`                       | QQ Bot Open Platform (q.qq.com); empty → QR-code login on the channel's first start                                                              |
| OpenClaw overrides                           | `OPENCLAW_LLM_API_KEY` / `_BASE_URL` / `_MODEL`               | optional, per-field                                                                                                                              |
| OpenClaw dingtalk channel                    | `OPENCLAW_DINGTALK_ACCESS_TOKEN` / `OPENCLAW_DINGTALK_SECRET` | an independent dingtalk app — never shared with the Qwen Code one                                                                                |
| OpenClaw QQ Bot channel                      | `QQBOT_APP_ID` / `QQBOT_CLIENT_SECRET`                        | the official plugin's OWN env names (no config fields); an independent QQ bot — never shared with Qwen's                                         |
| Qwen serve daemon (auto-generated)           | `QWEN_SERVER_TOKEN`                                           | auto-generated at install (`openssl rand -hex 32`) → `--require-auth`; a hand-set value wins; emptying it by hand → token-less loopback (warned) |
| OpenClaw gateway (auto-generated)            | `OPENCLAW_GATEWAY_TOKEN`                                      | same posture for the gateway control plane (dashboard + agent API) on 127.0.0.1:18789                                                            |

Notes:

- **Only secrets need exporting**: an unset variable renders an empty
  field (never a blocked install); checkhealth's presence + connectivity
  sections then tell you exactly what to fill. No public endpoint/model
  defaults are baked in.
- The two daemon tokens are auto-generated by install.sh's shared
  secrets step (only when empty; gated on the agent being enabled) and
  persisted in secrets.env — the single source of truth; re-runs never
  rotate them behind your back.
- Override layers are per-field: an unset `OPENCODE_LLM_MODEL` falls
  back to the shared `LLM_MODEL`, so overriding one field never requires
  writing the full triple.
- `secrets.env.template` documents the full variable set, grouped per
  agent — it is also the seed template the installer renders the real
  file from.
- The installer appends one marker-guarded block to `~/.zprofile` (the
  login profile, with `set -a` so the values land in the environment)
  that sources the secrets file into every login shell; block ordering
  across components is the framework's head/normal/tail partition
  (secrets sort before the exec-style autostart blocks). Remove those
  lines to disable.

## What gets installed

### OpenCode

- Binary via npm (`npm install -g opencode-ai` — the same lane as every
  other agent, one upgrade path); the official script
  (`curl -fsSL https://opencode.ai/install | bash`) is the fallback for
  hosts without node/npm. Skipped when already present.
- Config rendered to `~/.config/agent/opencode.json` and symlinked from
  `~/.config/opencode/opencode.json`.
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
  base URL and model render as empty fields until secrets.env provides
  them (no public defaults).

### Qwen Code

- Node.js 22+ / npm auto-installed (via the framework's node provisioning),
  then `npm install -g @qwen-code/qwen-code` (bin: `qwen`).
- `~/.qwen/settings.json` (symlinked from
  `~/.config/agent/qwen/settings.json`) — provider, model, and the
  dingtalk + QQ Bot channels inlined; credentials render as `$VAR` name
  references.
- ONE resident service: `qwen-serve.service` — `qwen serve --channel`
  hosts the loopback HTTP/Web Shell API (127.0.0.1:4170) AND both
  channel adapters in a single daemon. Status:
  `systemctl --user status qwen-serve.service` (macOS launchd label
  `com.qwenlm.qwen-serve`). Linger is enabled best-effort.
- Credentials come from the shared secrets.env (the unit's
  `EnvironmentFile=`), so a shell export is enough for the interactive
  TUI and a file edit + `systemctl --user restart` covers the daemon.
- `QWEN_SERVER_TOKEN` is auto-generated at install (openssl rand -hex
  32, persisted in secrets.env) — the daemon boots with
  `--require-auth`; emptying the variable by hand reverts to token-less
  on loopback (warned).
- QQ Bot: with `QWEN_QQ_APP_ID` / `QWEN_QQ_APP_SECRET` set, the channel
  connects with them; empty, the channel falls back to QR-code login on
  first start.

### OpenClaw

- Node.js 24.16+ / 26.1+ floor (higher than the other agents) via the
  framework's node provisioning (Homebrew covers hosts whose distro
  index is too old), then `npm install -g openclaw@latest`
  (`--allow-scripts=openclaw` on npm 11.16+/12), falling back to the
  official installer script.
- Two official channel plugins are installed
  (`openclaw plugins install`): `@dingtalk-real-ai/dingtalk-connector`
  and `@tencent-connect/openclaw-qqbot` — neither is a core OpenClaw
  channel. Upstream gates npm-sourced plugins behind a manual
  trust/capability review; the installer warns with the exact command
  (rerun with `--force` after approving) and renders the config without
  the unapproved channel.
- Config rendered to `~/.config/agent/openclaw/openclaw.json` and
  installed as a **regular file copy** at `~/.openclaw/openclaw.json` —
  deliberately NOT a symlink: upstream replaces the config atomically
  and warns against symlinked layouts. Re-running the installer
  re-renders and overwrites hand edits (the template is the structural
  truth).
- Credentials: the single `~/.config/agent/secrets.env` (0600) — the gateway reads it via the unit's EnvironmentFile=; the config references variables BY NAME.
- The gateway runs as a resident service: `openclaw-gateway.service`
  (macOS launchd label `com.openclaw.gateway`), loopback
  `127.0.0.1:18789`, with the cron engine (scheduled wake-ups) enabled.
  `OPENCLAW_GATEWAY_TOKEN` is auto-generated at install (persisted in
  secrets.env) — the gateway boots with token auth; emptying it by hand
  reverts to token-less on loopback (warned). The QQ Bot channel's
  credentials use the upstream's own env names (`QQBOT_APP_ID` /
  `QQBOT_CLIENT_SECRET` in secrets.env) — no config fields.

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
(`$__X__` placeholders), plugin lists, service units. The installer
renders the templates with envsubst (gettext — placeholders only, no
format awareness) and writes the result atomically with 0600
permissions into `~/.config/agent/` — company URLs, model ids and keys
exist only there, never in the checkout. `~/.config/opencode/opencode.json`
and friends are symlinks into that directory; rendered files are
regenerated on every install, so hand-edits to a rendered file get
overwritten — change the template or the secrets file instead.

No secret value ever lands in a rendered config: every agent renders a
variable NAME reference (`{env:NAME}` / `apiKeyEnv` / `"$VAR"` /
`${VAR}`) and the value reaches the process through the environment
(secrets.env, sourced with `set -a`). The fill mode (render's
`fill KEY...`) is the value-merging path: it backfills empty `KEY=`
lines from the environment while preserving hand-edited values —
secrets.env itself is rendered this way (seeded from
secrets.env.template).

When the installer must replace a foreign config file (the `takeover`
link mode), it first moves the original to `<file>.link-bak`. Block
ordering in the login profile is the framework's head/normal/tail
stable partition — the secrets block (head) always lands before the
exec-style autostart blocks (tail), regardless of install order.

## Check health

```bash
./checkhealth.sh [--install]
```

Four kinds of checks (three-state `[ OK ] / [WARN] / [FAIL]` output):

1. **Tool health** — opencode / dsh / qwen / openclaw binaries and
   versions, plus each agent's Node.js floor.
2. **Secrets health** — secrets.env presence and 0600 permissions,
   required variables non-empty (names only, never values).
3. **Connectivity** — a minimal authenticated request (`GET {baseURL}/models`,
   ~10s timeout) against the base URL read from the rendered configs;
   WARN-level, advisory only. Export `SKIP_CONNECTIVITY=1` to skip on
   offline machines.
4. **Resident process health** — the gateway / serve service state,
   the serve daemon's loopback health endpoint, and the channels'
   outbound reachability (api.dingtalk.com / api.sgroup.qq.com route
   probes, credential-gated — all WARN-level).

Agent folders register their own sections; `--install` installs missing
dependencies. Run it after installing to see what is missing.

## Troubleshooting

- **"No systemd user session" (WSL / containers)**: resident service
  registration is skipped with a WARN — the unit files still land under
  `~/.config/systemd/user/`, and checkhealth reports the service state
  as unknown. Run on a host with a systemd user session, or start the
  processes by hand.
- **Channel credentials unresolved**: the rendered configs carry the
  variable names, so an empty secrets.env leaves the channels
  disconnected. Fill the dingtalk pairs (`QWEN_DINGTALK_*` and
  `OPENCLAW_DINGTALK_*` — two independent dingtalk apps; Stream Mode
  enabled in the developer portal) and the QQ pairs (`QWEN_QQ_*` or
  leave empty for QR-code login; `QQBOT_APP_ID` / `QQBOT_CLIENT_SECRET`
  for OpenClaw — from the QQ Bot Open Platform, q.qq.com), then re-run.
  After a credentials change restart the daemons:
  `systemctl --user restart qwen-serve.service openclaw-gateway.service`.
- **Connectivity WARNs in checkhealth**: advisory only — they never fail
  the run or the install. Offline machines: `export SKIP_CONNECTIVITY=1`.
- **Binary installed but "not on this shell's PATH"**: the installer
  cannot modify the running shell — open a new shell (or `exec zsh`).
- **dsh plugins not active**: plugin bundles load on the next `dsh web`
  start — restart the web profile if it is running.
- **Hand-edited rendered config got overwritten**: by design — the
  template is the structural truth. Change the template, or put the
  value in secrets.env.

## Layout

```text
install.sh            one-shot installer (agent selection via --with-*)
checkhealth.sh        dependency + health check
lib/agent.sh          shared helpers: secrets resolution, credential fill,
                      block wiring, agent contract (rendering lives in the
                      framework: scripts/lib/template.sh)
secrets.env.template   the full local-values variable set, grouped per agent
<agent>/              one folder per agent — templates and agent-specific
                      files only; each defines install_agent_<name>() /
                      checkhealth_agent_<name>() for the entry points to call
scripts/              shared installer/check framework (a `git subtree` of
                      github.com/QMonkey/monkey-scripts)
```

Adding an agent means adding one folder — the skeleton and framework stay untouched.
