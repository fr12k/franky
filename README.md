# franky

A provider-agnostic, streaming LLM agent framework written in **Zig 0.17-dev**.

Franky is a layered runtime for building tool-using AI agents. It ships
with a complete coding-agent CLI out of the box — seven LLM providers
(Anthropic, OpenAI Chat, OpenAI Responses, OpenAI-compatible gateways,
Google Gemini, Google Vertex, plus a scripted fake), a stateful agent
loop with parallel tool execution, built-in `read` / `write` / `edit` /
`bash` / `ls` / `find` / `grep` tools (with regex, gitignore, atomic
edits, and §R workspace path-safety), session persistence + branching
on disk, **four run modes** (`print` / `interactive` / `rpc` / `proxy`),
a built-in web UI served by proxy mode, capability roles, a per-tool
permission overlay, bearer-token auth (`--auth-token` /
`ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN`) for subscription /
gateway flows, and per-phase HTTP timeouts. **881 tests** pass at the
current cut.

## Quick start

```sh
# Build
zig build

# Run (offline, no API key needed — uses the faux provider)
./zig-out/bin/franky "hello"
# → you said: hello

# Run against the real Anthropic API
export ANTHROPIC_API_KEY=sk-ant-…
./zig-out/bin/franky "refactor foo.zig"

# Interactive TUI
./zig-out/bin/franky --mode interactive

# Web UI (HTTP/SSE listener on http://127.0.0.1:8787/)
./zig-out/bin/franky --mode proxy

# Proxy mode with orchestrator registration
./zig-out/bin/franky --mode proxy --register http://localhost:9000

# Run tests
zig build test
```

With no flags and no API key in the environment, franky defaults to the
**faux provider** — a scripted fake LLM — so the binary runs end-to-end
without network access.

## Getting Started with `sbx` sandbox

Franky ships with a [`Dockerfile.sandbox`](Dockerfile.sandbox) that
builds a container with Zig 0.17-dev, Go, Rust/Cargo, and the latest
franky binary pre-installed, along with a pre-configured
[`settings.json`](settings.json) that includes ready-to-use profiles
for non-local models. Use the `sbx` CLI to create and manage sandboxed
environments from this template.

```sh
# Create a sandbox from the containifyci claude-code template
sbx create --name franky --template containifyci/claude-code shell <workspace>

# Set API keys (example: Ollama — repeat for other providers)
sbx secret set-custom -g --host ollama.com --env OLLAMA_API_KEY --value <your-key>

# Publish ports so the proxy web UI is reachable from the host
sbx ports franky --publish 8787:8787

# Run the sandbox
sbx run franky

# Run sbx dashboard in another terminal to see the active sandboxes
sbx
```

Inside the sandbox the `settings.json` is already copied to
`~/.franky/settings.json`, so you can start franky using any of the
pre-defined profiles:

| Profile | Provider | Model |
|---|---|---|
| `cerebras` | Cerebras Gateway | qwen-3-235b-a22b-instruct-2507 |
| `cloudflare` | Cloudflare Workers AI | @cf/moonshotai/kimi-k2.6, @cf/nvidia/nemotron-3-120b-a12b |
| `mistral` | Mistral API | devstral-2512, mistral-medium-3-5, codestral-2508, labs-leanstral-2603 |
| `ollama-cloud` | Ollama Cloud | deepseek-v4-flash:cloud, kimi-k2.6:cloud, deepseek-v4-pro:cloud, gemma4:31b-cloud, minimax-m3:cloud, glm-5.1:cloud |
| `ollama-home` | Ollama Home (192.168.1.109) | gemma4:31b, qwen3.6:latest |
| `ollama-local` | Ollama Local (localhost) | gemma4:latest, granite4.1:30b |
| `openrouter` | OpenRouter | openrouter/owl-alpha |
| `google` | Google Gemini | gemini-2.5-pro |
| `gemini` | Google Gemini | gemini-2.5-pro, gemini-3.1-pro-preview |
| `openai` | OpenAI | gpt-5.4-mini-2026-03-17 |

For example, to start the proxy web UI with the Ollama Cloud DeepSeek Flash
profile:

```sh
cd /workspace/franky
./zig-out/bin/franky --mode proxy --profile ollama-cloud/deepseek-v4-flash:cloud
```

Then open `http://localhost:8787/` on the host.

See [`SANDBOX.md`](SANDBOX.md) for the full list of provider secret
recipes (Cerebras, Cloudflare, Mistral, OpenRouter, Gemini, OpenAI)
and the `sbx secret set-custom` commands that go with each.

## Requirements

- **Zig master / 0.17.0-dev** — uses `std.Io`, `std.Io.Dir` /
  `std.Io.File`, and `std.process.Init`. Homebrew's `zig 0.16` is
  insufficient; pull a 0.17-dev tarball from
  [ziglang.org/download/](https://ziglang.org/download/) or use
  `brew install --HEAD zig`.
- **Linux, macOS, or BSD.** Windows is untested.

## Capabilities at a glance

| Feature | Default | Enable | Disable |
|---|---|---|---|
| **Provider** | auto-selected from API keys; `faux` if none | `--provider <name>` (`anthropic` / `openai_chat` / `openai_responses` / `openai_gateway` / `google_gemini` / `google_vertex` / `faux`) | `--offline` forces faux even when a key is set |
| **Run mode** | `print` (one prompt → output → exit) | `--mode interactive` (TUI) / `--mode rpc` (JSON-RPC over stdio) / `--mode proxy` (HTTP/SSE + web UI) | n/a — explicit choice per run |
| **Capability role** | `plan` (read + workspace writes, no shell) | `--role read` / `--role plan` / `--role code` (adds bash) / `--role full` (no §R restrictions) | n/a — always bound at session init |
| **Permission overlay** | off | `--prompts` toggles the gate. Pair with `--yes` (CI), `--allow-tools <csv>`, `--deny-tools <csv>`, or `--ask-tools <csv>` (or `--ask-tools all` for ask-on-every-call) | omit `--prompts` |
| **Sandbox** | host process (auto-detected) | run in a container (see `docs/sandbox.md` recipes) | n/a — recommendation, not enforced |
| **Reasoning** | off | `--thinking minimal\|low\|medium\|high\|xhigh` | `--thinking off` |
| **Session persistence** | on (writes to `~/.franky/sessions/<ulid>/`) | default | `--no-session` |
| **Resume / branching** | new session per run | `--continue` (most recent) or `--resume <id>`; `--fork <name>` / `--checkout <name>` | n/a |
| **Phase timeouts** | 10 s connect / 120 s upload / 30 s first-byte / 60 s event-gap (10 min first-byte when `--base-url` points at a loopback host) | `--connect-timeout-ms` / `--upload-timeout-ms` / `--first-byte-timeout-ms` / `--event-gap-timeout-ms` (or matching `FRANKY_*_TIMEOUT_MS` env vars) | set field to `0` to disable that phase's watchdog |
| **Bearer-token auth** | API-key path | `--auth-token <token>` (or `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` env vars). Mint long-lived tokens externally — e.g. `claude setup-token` — and paste the result in. | n/a |
| **Logging** | warnings + errors → stderr | `--log-level info\|debug\|trace` or `FRANKY_LOG=…` or `FRANKY_DEBUG=1`; route to a file with `--log-file PATH` (or `FRANKY_LOG_FILE`); interactive mode auto-diverts above `warn` to `$FRANKY_HOME/logs/franky-<ts>.log` so the TUI stays usable | `--log-level error` |
| **Tool subset** | every built-in tool | `--tools read,grep,…` (registry filter) | n/a — pair with `--role` for capability-tier scoping instead |
| **Skills / templates** | n/a | `--skills <path>`, `--prompts-dir <dir>` (template root, was `--prompts` before v1.11.0) | omit |
| **Orchestrator registration** | off | `--register <url>` (or `FRANKY_ORCHESTRATOR_URL`); proxy calls `POST /register` / `POST /unregister` with exponential backoff | omit `--register` |
| **Extensions (Tier-1)** | none loaded | `--extensions <csv>` of built-in module names | omit |

## Using the CLI

### Provider selection

`--provider` is inferred from the presence of an API key; pass it
explicitly to override. Each provider has its own env-var fallback —
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, etc.

```sh
# Auto-detect (Anthropic API key in env)
./zig-out/bin/franky "explain this code"

# Explicit provider + model
./zig-out/bin/franky --provider anthropic --model sonnet "explain this code"

# Model aliases: opus, sonnet, haiku (resolve to current Anthropic model ids)
./zig-out/bin/franky --model opus "complex refactor task"

# OpenAI-compatible local gateway (Ollama, LM Studio, vLLM, …)
./zig-out/bin/franky --provider openai_gateway \
    --base-url http://localhost:11434/v1/messages \
    --model llama3 "summarize"
```

### Run modes

`--mode <print|interactive|rpc|proxy>` picks how franky drives the agent
loop. Default is `print`.

```sh
# Print (default): one-shot prompt → streamed output → exit.
franky "what's in foo.zig?"

# Interactive: full TUI with scrollback + slash commands.
franky --mode interactive
#  /help      list slash commands
#  /role      show the active capability role + permitted tools
#  /tools     list registered tools
#  /branch    list / create / checkout session branches
#  /compact   summarize earlier turns (frees context window)
#  /retry     re-run the last user turn
#  /export    dump transcript as markdown / json

# RPC: LSP-style JSON-RPC over stdio for programmatic clients.
echo 'Content-Length: 14\r\n\r\n{"method":"ping"}' | franky --mode rpc

# Proxy: HTTP/SSE listener + built-in web UI on http://127.0.0.1:8787/
franky --mode proxy
# GET /events   — Server-Sent Events stream of AgentEvents
# POST /prompt  — submit a prompt, run one turn under run_mutex
# GET /role     — active role + permitted tools + sandbox status
# POST /abort   — fire the cancel flag
# GET /transcript, GET /sessions, POST /session/new, …

# Proxy with orchestrator registration:
# `--register` tells franky to POST to the orchestrator after binding
# its listen socket (POST /register) and POST /unregister on shutdown.
# Registration is best-effort — the proxy continues standalone if the
# orchestrator is unreachable. Retries with exponential backoff (1s→30s).
# Env override: FRANKY_ORCHESTRATOR_URL
franky --mode proxy --register http://localhost:9000
# The registration payload advertises apiUrl as http://127.0.0.1:PORT
# (reachable from the host via Docker port mapping when running in a
# container), session id, model, role, workspace, and host PID.
```

### Capability roles (§5.10)

A **role** is a coarse capability tier picked at session init. It
filters which built-in tools the model sees; a runtime gate also
catches calls to disabled tools that the model "remembers" from prior
context. Default is `plan`.

| Role | Permitted tools | Use case |
|---|---|---|
| `read` | `read`, `ls`, `find`, `grep` | Inspection / CI review jobs |
| `plan` *(default)* | `plan` + `write`, `edit` | Workspace-scoped writes, no shell |
| `code` | `plan` + `bash` (cwd-locked, env-denylisted) | Default for sandboxed runs |
| `full` | every tool, no §R restrictions | Trusted sandbox / VM only |

```sh
franky --role read --mode print "summarize the diff in this PR"
franky --role code --mode interactive
```

The role binds at session init — there is no mid-session escalation. To
change role, restart franky. The `/role` slash command in interactive
mode is read-only.

When you select `code` or `full` outside a detected sandbox a yellow
banner reminds you to wrap the run in a container or equivalent isolation.

### Per-tool permission overlay (§5.11)

Layered on top of roles: roles control which tools the model *sees*;
the permission overlay controls which calls actually *run*. Off by
default; opt in with `--prompts`.

| Flag | Effect |
|---|---|
| `--prompts` | Master toggle. Enables the gate. |
| `--yes` / `-y` | Every "ask" decision becomes auto-allow. CI mode. |
| `--allow-tools <csv>` | Allowlist by tool name (`write`) or scoped bash fingerprint (`bash:git`). |
| `--deny-tools <csv>` | Denylist; takes precedence over allow. |
| `--ask-tools <csv>` | Demote default-auto_allow tools to "ask" (e.g. `read,find`). Reserved sentinel `all` flips every default-auto_allow tool. |
| `--remember-permissions` | Persist `Always *` decisions across runs to `$FRANKY_HOME/permissions.json`. |

**Precedence** (most → least specific): `--deny-tools` →
`--allow-tools` → `--ask-tools` → default policy.

**Persistence** (v1.12.0). Without `--remember-permissions`, every
`Always allow / Always deny` decision is session-only — picking
`Always allow bash:git` once doesn't carry into the next run. With
the flag, those promotions land atomically in
`$FRANKY_HOME/permissions.json` (`~/.franky/permissions.json` if
`FRANKY_HOME` isn't set) and are loaded back on session init. The
schema is sorted-key for diff-friendly dotfile checkin:

```json
{
  "version": 1,
  "always_allow": { "tools": ["write"], "bash": ["git", "ls"] },
  "always_deny":  { "tools": [],         "bash": ["rm", "curl"] }
}
```

Disk hiccups never abort an in-flight turn — failed writes / missing
HOME / corrupt JSON degrade silently to in-memory-only state.

**Curating the persisted set** (v1.15.2). Inside `--mode
interactive`:

```
/permissions             — show status + every entry, alphabetized
/permissions clear       — wipe every allow/deny/ask entry + flags
/permissions revoke X    — drop one entry by name
                            (e.g. `bash:git`, `write`, `read`)
```

`clear` and `revoke` auto-write back to `permissions.json` when
the bot was started with `--remember-permissions`, so changes
survive across sessions.

**Default policy (when `--prompts` is on):** `read` / `ls` / `find` /
`grep` auto-allow; `write` / `edit` / `bash` ask.

**Bash fingerprint** — verb-level (first non-path token):
`"git status"` → `git`, `"npm install foo"` → `npm`,
`"/usr/local/bin/zig build"` → `zig`. So `--allow-tools bash:git`
allows every git invocation but not `rm`/`curl`/etc.

```sh
# CI: ask is auto-allow, gate is active.
franky --prompts --yes "..."

# Allowlist a known-safe set; deny destructive bash verbs.
franky --prompts \
    --allow-tools read,write,edit,bash:git,bash:ls,bash:cat \
    --deny-tools  bash:rm,bash:curl,bash:sudo \
    "..."
```

**Interactive modal (v1.11.2).** `franky --prompts --mode interactive`
is the canonical "ask before every tool call" entry point. When the
agent attempts a write/edit/bash that the policy would `ask` for, the
TUI appends a yellow modal overlay to the scrollback:

```
🔒 permission required: bash (fingerprint: rm)
   args: {"command":"rm -rf /tmp/foo"}
   [a]llow once  [A]lways allow  [d]eny once  [D]eny always  (Esc=deny)
```

Press one of `a / A / d / D / Esc`. `*_always` decisions get
remembered per-fingerprint for the rest of the session; `*_once`
decides only the in-flight call. Esc and any unrecognized key
default to `deny_once` — explicit choice is required (no
"Enter accepts").

**RPC mode (v1.11.3).** Same overlay shape, JSON-RPC transport.
Server emits `tool_permission_request` as a `method:"event"`
notification (`params` carry `callId`, `toolName`, `argsJson`,
`fingerprint`); client replies with the `permission/resolve` method
taking `{call_id, resolution}`. The RPC dispatcher interleaves
incoming frames with the agent loop's event drain so a client can
resolve while a prompt is in flight; nested `prompt` calls return
`error.PromptInFlight`.

**Proxy + web UI (v1.11.4).** SSE `tool_permission_request` event
fires when the gate suspends; `web/app.js` renders a yellow inline
modal in the conversation pane with four buttons (`Allow once` /
`Always allow` / `Deny once` / `Always deny`). Click POSTs to
`POST /permission/resolve` with `{call_id, resolution}`; the modal
collapses to a green ✓ or red ✗ result line.

> **Print mode is non-interactive by design** — use `--yes` or
> `--allow-tools` for CI / one-shot runs. The interactive prompt UX
> requires a TUI / RPC client / browser.

### CLI flags

Full list: `franky --help`. Highlights:

| Flag | Purpose |
|---|---|
| `--provider NAME` | `faux` / `anthropic` / `openai_chat` / `openai_responses` / `openai_gateway` / `google_gemini` / `google_vertex` |
| `--model ID` | Model id or alias (`opus`, `sonnet`, `haiku`) |
| `--api-key KEY` | API key (provider-dependent header); env fallbacks per provider |
| `--auth-token TOKEN` | OAuth / JWT bearer token for subscription auth |
| `--base-url URL` | Endpoint override for `openai_gateway` and other compatible servers |
| `--system-prompt TEXT` / `--append-system-prompt TEXT` | Override / extend system prompt |
| `--thinking LEVEL` | `off` / `minimal` / `low` / `medium` / `high` / `xhigh` |
| `--mode MODE` | `print` / `interactive` / `rpc` / `proxy` |
| `--proxy-port N` | TCP port for `--mode proxy` (default 8787) |
| `--register URL` | Orchestrator base URL; proxy calls `POST /register` after binding and `POST /unregister` on shutdown. Env: `FRANKY_ORCHESTRATOR_URL` |
| `--role NAME` | `read` / `plan` / `code` / `full` (default `plan`) |
| `--prompts` / `--yes` / `--allow-tools` / `--deny-tools` / `--ask-tools` / `--remember-permissions` | Permission overlay (§5.11) |
| `--connect-timeout-ms N` etc. | Per-phase HTTP watchdogs (§G.4) |
| `--session ID` / `--resume ID` / `--continue` / `--no-session` | Session control |
| `--session-dir DIR` | Override `$FRANKY_HOME/sessions` (default `~/.franky/sessions`) |
| `--fork NAME` / `--checkout NAME` | Branching (§5.1) |
| `--export FORMAT` | Dump transcript (`markdown` / `json`) and exit |
| `--tools LIST` | Comma-separated registry filter for this run |
| `--skills PATH` / `--prompts-dir DIR` | Skill bundle / template lookup root |
| `--extensions LIST` | Opt-in Tier-1 extensions |
| `--offline` | Force faux provider even when a key is set |
| `--log-level LEVEL` / `--verbose` | `error` / `warn` / `info` / `debug` / `trace` |
| `--log-file PATH` | Route logs to PATH instead of stderr (env: `FRANKY_LOG_FILE`). Interactive mode auto-diverts above `warn` to a default path so the TUI stays clean. |
| `-h` / `--help`, `--version` | Help + version |

### Environment variables

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | API key fallback (sent as `X-Api-Key`) |
| `ANTHROPIC_AUTH_TOKEN` | Bearer-token fallback (proxies / gateways) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Long-lived OAuth token from `claude setup-token` |
| `OPENAI_API_KEY` | OpenAI / openai-compatible gateway fallback |
| `GOOGLE_API_KEY` / `GEMINI_API_KEY` | Google Gemini fallback |
| `GOOGLE_APPLICATION_CREDENTIALS` | Vertex AI service-account JSON path |
| `FRANKY_HOME` | Session dir root (default: `~/.franky`) |
| `FRANKY_LOG` | Log level: `error` / `warn` / `info` / `debug` / `trace` |
| `FRANKY_LOG_FILE` | Override `--log-file` |
| `FRANKY_DEBUG` | `1` or `true` → debug level |
| `FRANKY_ORCHESTRATOR_URL` | Override `--register`; orchestrator base URL for agent registration |
| `FRANKY_CONNECT_TIMEOUT_MS` / `FRANKY_UPLOAD_TIMEOUT_MS` / `FRANKY_FIRST_BYTE_TIMEOUT_MS` / `FRANKY_EVENT_GAP_TIMEOUT_MS` | Override the matching `--*-timeout-ms` flag |
| `ZEROBOX_ACTIVE` | Set externally to silence the sandbox warning |

Commands run by the LLM-callable `bash` tool also receive current session metadata:

| Variable | Purpose |
|---|---|
| `FRANKY_SESSION_ID` | Current session ID |
| `FRANKY_SESSION_FILE` | Absolute transcript JSON path; unset for ephemeral / in-memory sessions |
| `FRANKY_PROVIDER` | Currently selected model provider |
| `FRANKY_MODEL` | Currently selected model ID |
| `FRANKY_REASONING_LEVEL` | Current effective reasoning level: `off`, `minimal`, `low`, `medium`, `high`, or `xhigh` (unset when `off`) |

These are resolved when each command starts, so switching models or changing the reasoning level affects the next bash command without restarting. The bash tool description includes a hint to inspect these instead of inferring the model from the system prompt. Custom / factory-created bash tools can opt out via `expose_session_environment = false` on the `SessionBashState`; inherited values are still scrubbed so nested franky processes don't leak stale parent-session metadata.

### Bearer-token auth

Franky no longer ships a built-in OAuth/PKCE/device-code minting flow
(`franky login` was removed). The runtime still consumes bearer tokens
in two ways:

1. **`--auth-token <token>`** on the CLI, with env-var fallbacks
   (`ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`) — the value flows
   into `Options.auth_token` and the provider sends
   `Authorization: Bearer <token>` plus the Claude Code fingerprint
   headers (see `src/ai/providers/AUTH.md`).
2. **`auth.json` records of `type: "oauth"`** — written by hand or by
   an external tool, with `accessToken` / `refreshToken` / `expiresAt`
   in the §H.1 shape. Franky reads the record but does not refresh it.

Long-lived subscription tokens are minted externally — for Claude
Pro/Max/Team/Enterprise, `claude setup-token` (the official Claude
Code CLI) prints a one-year token that you paste into
`--auth-token` or export as `CLAUDE_CODE_OAUTH_TOKEN`. Other providers
mint tokens via their own tooling.

### Sandboxing

`--role code` and `--role full` execute shell commands on the host
filesystem. Wrap them in a sandbox when running against untrusted
prompts. Zerobox-style process isolation or Docker are the canonical
wrappers:

```sh
# Using Docker (see docs/sandbox.md for recipes)
docker run --rm -v "$(pwd):/workspace" ...
```

Recipes for Docker, devcontainer, Lima, and the Slack-bot
(`franky-do`) pattern live in [`docs/sandbox.md`](docs/sandbox.md).

### Sessions on disk

Unless you pass `--no-session`, each run writes to
`$FRANKY_HOME/sessions/<ulid>/session.json`,
`.../transcript.json`, `.../tree.json` (branch graph), and an
`object_store/` directory for content-addressed blobs ≥32 KiB. Pass
`--continue` (most recent) or `--resume <ulid>` on the next run to
continue the conversation. `--fork <name>` and `--checkout <name>`
operate on the branch tree. Writes are atomic (tempfile + rename) and
versioned.

## Architecture

Franky is organized as three layered modules. Each layer depends only on
the one below it:

```
┌──────────────────────────────────────────────────┐
│  coding   — tools, session, CLI modes            │
├──────────────────────────────────────────────────┤
│  agent    — stateful, tool-using runtime         │
├──────────────────────────────────────────────────┤
│  ai       — provider-agnostic LLM streaming      │
└──────────────────────────────────────────────────┘
```

- **`ai`** stands alone — a streaming LLM client with provider registry,
  SSE parser, incremental JSON parser, bounded event channels, and a
  normalized stream-event model.
- **`agent`** adds the turn-based state machine on top — tool dispatch,
  transcript management, hooks, and the stateful `Agent` wrapper with
  background worker threads and subscriber broadcast.
- **`coding`** adds a particular tool/prompt set — the seven built-in
  file/shell tools, session persistence, CLI argument parsing, and the
  print-mode driver.

## Project layout

```
src/
  root.zig             # Library root (re-exports ai, agent, coding, tui, sdk)
  sdk.zig              # Programmatic SDK facade (§5.9)
  test_helpers.zig     # Shared test Io helpers

  ai/                  # Provider-agnostic LLM streaming
    mod.zig            # Module root
    types.zig          # Context, Message, ContentBlock, Usage, Tool, Model, ThinkingLevel
    errors.zig         # AgentError + ErrorDetails (error taxonomy)
    sse.zig            # Server-Sent Events parser
    partial_json.zig   # Incremental JSON parser for streaming tool-call args
    channel.zig        # Bounded event channel with drop-hook cleanup
    stream.zig         # StreamEvent, Reducer, drainToMessage, Cancel
    registry.zig       # API-tag → StreamFn dispatch
    http.zig           # HTTP + SSE streaming transport
    retry.zig          # Retry logic for transient errors
    log.zig            # Leveled stderr logger (err/warn/info/debug/trace)
    transform.zig      # Cross-provider message transform (thinking-block adaption)
    providers/
      AUTH.md          # Authentication schemes documentation
      anthropic.zig    # Anthropic Messages API (full SSE translation)
      faux.zig         # Scripted test provider
      google_gemini.zig    # Google Gemini provider
      google_vertex.zig    # Google Vertex AI provider
      openai_chat.zig      # OpenAI Chat API provider
      openai_gateway.zig   # OpenAI-compatible gateway adapter
      openai_responses.zig # OpenAI Responses API provider

  agent/               # Stateful, tool-using runtime
    mod.zig            # Module root
    types.zig          # AgentEvent, AgentTool, ToolResult
    loop.zig           # agentLoop — the low-level turn state machine
    agent.zig          # Stateful Agent class (worker thread + subscribers)

  coding/              # The coding-agent layer
    mod.zig            # Module root
    cli.zig            # CLI argument parsing
    session.zig        # session.json + transcript.json round-trip (ULID, atomic writes)
    settings.zig       # $FRANKY_HOME/settings.json runtime limits
    auth.zig           # $FRANKY_HOME/auth.json bearer token records
    models.zig         # §H.3 model catalog + lookup
    models_fetch.zig   # Provider endpoint pollers for gen-models
    models_render.zig  # Model catalog renderer
    role.zig           # Capability tiers (read/plan/code/full)
    permissions.zig    # Tool permission overlay with --allow-tools/--deny-tools/--ask-tools
    path_safety.zig    # Workspace path canonicalization + escape detection
    gitignore.zig      # Multi-level .gitignore parsing with negation
    env_denylist.zig   # Blocks dangerous env vars from bash subprocesses
    extensions.zig     # Tier-1 static module extension loading
    regex.zig          # Regex engine (gitignore-aware)
    tools/
      read.zig         # Read file (line-numbered, binary/size guards)
      write.zig        # Atomic file creation (clobber protection)
      edit.zig         # Atomic multi-edit (find/replace)
      bash.zig         # Shell execution (cwd-locked, env-denylist, timeout)
      ls.zig           # Directory listing (recursive, gitignore-aware)
      find.zig         # Glob-based file search
      grep.zig         # Literal-substring + regex search
      subagent.zig     # Sub-agent delegation
      web_search.zig   # Web search
      web_fetch.zig    # Full page content fetch
      truncate.zig     # Output truncation utility
      workspace.zig    # Workspace context tool
      common.zig       # Shared tool utilities
    modes/
      print.zig        # One-shot print-mode CLI driver
      interactive.zig  # Full TUI with scrollback + slash commands
      rpc.zig          # JSON-RPC over stdio for programmatic clients
      proxy.zig        # HTTP/SSE listener (127.0.0.1:8787) + built-in web UI
      web/
        index.html     # Web UI HTML
        app.js         # Web UI client (js)
        style.css      # Web UI styles

  tui/                  # Terminal UI components (interactive mode)
    mod.zig             # Module root
    buffer.zig          # Terminal screen buffer with double-buffering
    cell.zig            # Screen cell representation
    editor.zig          # Text editing widget
    text_buffer.zig     # Line-based text storage
    key_decoder.zig     # Terminal input parsing
    region.zig          # Screen region management
    keybindings.zig     # Configurable key binding system
    diff_renderer.zig   # Side-by-side diff display

  bin/
    main.zig              # CLI entrypoint (franky binary)
    gen_models.zig        # Model catalog regenerator
    franky_doctor.zig     # Cross-session self-improvement analyzer
    check_spec_anchors.zig # §-reference verifier

test/
  agent_loop_test.zig   # End-to-end: agent + faux + tool round-trip
  agent_class_test.zig  # Stateful Agent: subscribe/prompt/reset
  gitignore_test.zig    # Multi-level .gitignore with real filesystem tree
  parallel_tools_test.zig # Parallel tool execution correctness
  kitchen_sink_test.zig # Combined feature interaction
  replay_test.zig       # Session replay from stored transcripts

Dockerfile.sandbox    # Dev container with Zig 0.17-dev
```

## Using franky as a library

Add this directory as a module dependency in your `build.zig.zon`, then
import `franky` in your Zig code:

```zig
const franky = @import("franky");
const ai = franky.ai;           // provider layer
const agent = franky.agent;     // stateful runtime
const coding = franky.coding;   // tools, session, print mode
```

### 1. Stream an LLM response with the faux provider

```zig
const std = @import("std");
const franky = @import("franky");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Scripted fake provider — the backbone of the test suite.
    var faux = franky.ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "Hello, world!", .chunk_size = 4 } },
    } });

    // Register it in the provider registry.
    var reg = franky.ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    // Build a channel, invoke the provider, drain into a Message.
    var ch = try franky.ai.stream.Channel.initWithDrop(
        gpa, 64, franky.ai.stream.StreamEvent.deinit, gpa,
    );
    defer ch.deinit();

    try reg.stream(.{
        .allocator = gpa,
        .io = io,
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .context = .{ .system_prompt = "", .messages = &.{}, .tools = &.{} },
        .options = .{},
        .out = &ch,
    });

    var msg = try franky.ai.stream.drainToMessage(&ch, io, gpa, null, null, null);
    defer msg.deinit(gpa);

    std.debug.print("{s}\n", .{msg.content[0].text.text});
}

fn fauxShim(ctx: franky.ai.registry.StreamCtx) anyerror!void {
    const faux: *franky.ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try faux.runSync(ctx.io, ctx.context, ctx.out);
}
```

### 2. Use the Anthropic provider

```zig
var reg = franky.ai.registry.Registry.init(gpa);
defer reg.deinit();
try reg.register(.{
    .api = "anthropic-messages",
    .provider = "anthropic",
    .stream_fn = franky.ai.providers.anthropic.streamFn,
});

const model: franky.ai.types.Model = .{
    .id = "claude-sonnet-4-6",
    .provider = "anthropic",
    .api = "anthropic-messages",
    .context_window = 1_000_000,
    .max_output = 8192,
    .capabilities = .{ .vision = true, .tool_use = true, .reasoning = true },
};

try reg.stream(.{
    .allocator = gpa,
    .io = io,
    .model = model,
    .context = my_context,
    .options = .{ .api_key = std.posix.getenv("ANTHROPIC_API_KEY") },
    .out = &ch,
});
```

### 3. Drive the full agent loop with tools

```zig
const echo_tool: franky.agent.types.AgentTool = .{
    .name = "echo",
    .description = "echo the arguments back as text",
    .parameters_json = "{\"type\":\"object\"}",
    .execute = echoExec,
};

fn echoExec(
    _: *const franky.agent.types.AgentTool,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
    args_json: []const u8,
    _: *franky.ai.stream.Cancel,
    _: franky.agent.types.OnUpdate,
) anyerror!franky.agent.types.ToolResult {
    const text = try std.fmt.allocPrint(allocator, "got: {s}", .{args_json});
    const arr = try allocator.alloc(franky.ai.types.ContentBlock, 1);
    arr[0] = .{ .text = .{ .text = text } };
    return .{ .content = arr };
}

var cancel = franky.ai.stream.Cancel{};
var transcript = franky.agent.loop.Transcript.init(gpa);
defer transcript.deinit();

var ch = try franky.agent.loop.AgentChannel.initWithDrop(
    gpa, 128, franky.agent.types.AgentEvent.deinit, gpa,
);
defer ch.deinit();

franky.agent.loop.agentLoop(gpa, io, &transcript, .{
    .model = model,
    .system_prompt = "You are franky.",
    .tools = &[_]franky.agent.types.AgentTool{echo_tool},
    .registry = &reg,
    .cancel = &cancel,
}, &ch);

while (ch.next(io)) |ev| {
    switch (ev) {
        .message_update => |u| switch (u) {
            .text => |t| std.debug.print("{s}", .{t.delta}),
            else => {},
        },
        .tool_execution_end => |e| {
            std.debug.print("\n[tool {s} done]\n", .{e.call_id});
        },
        else => {},
    }
    ev.deinit(gpa);
}
```

The loop emits `turn_start` → `message_start/update/end` → one
`tool_execution_start`/`end` per call → a `toolResult` `message_end` → …
until the assistant stops or a tool returns `terminate = true`.

### 4. Use the stateful Agent wrapper

`Agent` wraps the loop with a worker thread, subscriber broadcast, and
command methods:

```zig
var a = try franky.agent.Agent.init(gpa, io, .{
    .model = model,
    .system_prompt = "You are franky.",
    .tools = &[_]franky.agent.types.AgentTool{echo_tool},
    .registry = &reg,
});
defer a.deinit();

_ = try a.subscribe(onEvent, null);
try a.prompt("please call the echo tool");
a.waitForIdle();
```

| Method | Effect |
|---|---|
| `prompt(text)` | Append a user message and run one or more turns |
| `continueRun()` | Run without appending — useful after manual transcript edits |
| `abort()` | Fire the `Cancel` flag and join the worker |
| `reset()` | Abort and clear the transcript |
| `waitForIdle()` | Block until the worker exits |
| `setModel` / `setTools` / `setSystemPrompt` / `setThinking` | Update agent configuration |

### 5. Persist and resume sessions

```zig
const header: franky.coding.session.SessionHeader = .{
    .id = "01JXYZ…",
    .created_at_ms = now,
    .updated_at_ms = now,
    .title = "my chat",
    .provider = "anthropic",
    .model = "claude-sonnet-4-6",
    .api = "anthropic-messages",
    .thinking_level = "medium",
};

// Save:
try franky.coding.session.save(gpa, io, "~/.franky/sessions", header, &agent.transcript);

// Resume later:
var loaded = try franky.coding.session.load(gpa, io, "~/.franky/sessions", "01JXYZ…");
defer loaded.deinit(gpa);
// loaded.transcript is a Transcript ready to feed to an Agent.
```

### 6. Built-in tools

Register any of these in your `AgentTool` slice:

```zig
const read_tool = franky.coding.tools.read.tool();
const write_tool = franky.coding.tools.write.tool();
const edit_tool = franky.coding.tools.edit.tool();
const bash_tool = franky.coding.tools.bash.tool();
const ls_tool = franky.coding.tools.ls.tool();
const find_tool = franky.coding.tools.find.tool();
const grep_tool = franky.coding.tools.grep.tool();
```

| Tool | Schema (abbrev.) |
|---|---|
| `read` | `{path, offset?, limit?}` — line-numbered output, refuses binary & >256 KiB without explicit `limit` |
| `write` | `{path, content, overwrite?}` — atomic create; refuses to clobber by default |
| `edit` | `{path, edits: [{old, new, replaceAll?}]}` — all edits succeed atomically or none do |
| `bash` | `{command, cwd?, description?, timeoutMs?}` — shell execution via `/bin/sh -c` |
| `ls` | `{path?, recursive?, maxDepth?, respectGitignore?}` — directory listing |
| `find` | `{pattern, cwd?, limit?, respectGitignore?}` — glob-based file search |
| `grep` | `{pattern, path?, filesGlob?, caseSensitive?, maxMatches?, contextBefore?, contextAfter?}` — literal substring search |

## Design principles

- **Streams, not callbacks.** Every LLM interaction and agent turn is a
  sequence of events on a `Channel`. Completion is layered on top of
  streams (`drainToMessage`), not hidden underneath them.
- **Errors as events, not exceptions.** Below the CLI boundary, provider
  failures flow through the stream as `error_ev` events carrying structured
  `ErrorDetails`. Raising is reserved for programmer errors and OOM.
- **Plain-JSON persistence.** Contexts, transcripts, and sessions are
  structurally serializable. Session writes are atomic (tempfile + rename).
- **Hooks return decisions, not mutations.** `beforeToolCall` returns
  `{block, reason}` — it does not mutate the caller's state.
- **Deterministic transcripts.** Tool results are stored in source order
  regardless of completion order.
- **Layered modules.** `ai` stands alone; `agent` adds state machines on
  top; `coding` adds a particular tool/prompt set. You can use any layer
  independently.

## Implementation status

| Layer | Module | Status |
|---|---|---|
| `ai` | types, errors, sse, partial_json, channel, stream, registry, http (per-phase timeouts + retries), log | ✅ |
| `ai` providers | faux, anthropic, openai_chat, openai_responses, openai_gateway, google_gemini, google_vertex | ✅ (7 providers, full wire format + SSE) |
| `agent` | low-level loop (sequential + parallel-homogeneous), stateful `Agent` (worker thread + subscribers + steer/followUp drain) | ✅ |
| `coding` tools | read, write, edit (atomic), bash (cwd-locked + env-denylist + §R), ls, find, grep (regex + gitignore) | ✅ |
| `coding` modes | print, interactive (TUI), rpc (JSON-RPC), proxy (HTTP/SSE + web UI) | ✅ |
| `coding` features | session persistence + branching + object-store + compaction, capability roles (§5.10), permission overlay foundation (§5.11), settings/auth/models JSON, bearer-token auth (`--auth-token` + `auth.json` round-trip), Tier-1 extensions | ✅ |

**881 tests** pass at the current cut across one library binary and the
integration binaries (`agent_loop`, `agent_class`, `gitignore`,
`parallel_tools`, `kitchen_sink`). The `franky login` minting flow
shipped in v1.2.* and was removed in v1.30.0 — bearer tokens are now
minted externally.

### Profiling

CPU and memory flamegraphs against the test suite. Spec lives in
[`docs/spec/v2.md`](docs/spec/v2.md) §8; the long-form how-to was
archived to [`docs/archive/profiling_guide.md`](docs/archive/profiling_guide.md).

**Prerequisites** (Linux only — perf + heaptrack don't work on
macOS): `perf`, `heaptrack`, `heaptrack_print`, and `inferno-{collapse-perf,flamegraph,diff-folded}`
(install via `cargo install inferno`).

```sh
# 1. Build frame-pointer-preserved + libc-linked test binaries.
zig build test-profile

# 2. Capture CPU + all four memory flamegraphs against franky-test.
#    Output: zig-out/profile/franky-test/<unix_ms>/{cpu,mem-{peak,leaked,allocations,temporary}}.{folded,svg}
zig build profile

# Verify prereqs without capturing
zig build profile -- --check

# List installed test binaries
zig build profile -- --list

# CPU only / mem only against a different test binary
zig build profile -- --binary franky-parallel_tools_test --mode cpu
zig build profile -- --binary franky-kitchen_sink_test  --mode mem

# Narrow capture to a subset of tests (compile-time filter, repeatable)
zig build profile -Dprofile-filter=parallel
zig build profile -Dprofile-filter=edit -Dprofile-filter=grep

# Don't keep the raw perf.data / heaptrack.zst (renders SVGs, then deletes)
zig build profile -- --no-keep-trace
```

The four memory flamegraphs are `peak` / `leaked` / `allocations` /
`temporary` — see v2 §8.4 for what each one tells you.
`leaked.svg` should normally be empty (the test runner's GPA fails
on leaks); a non-empty leaked graph means an external tracer caught
something the GPA missed (typically C-malloc allocations from
vendored deps).

If a CPU flamegraph collapses to a single tower with no caller
context, frame pointers were stripped — see v2 §8.5.

### Regenerating `models.json`

```sh
# Render the built-in catalog as §H.3 JSON to stdout
zig build gen-models

# Poll live endpoints (each provider is included only when its env
# credential is set) and merge with the hand-curated built-ins
ANTHROPIC_API_KEY=sk-ant-… GEMINI_API_KEY=AIza… zig build gen-models -- --out ~/.franky/models.json

# Local Ollama models (no credential needed; `ollama serve` must be running)
zig build gen-models -- --providers ollama --no-builtin

# Help
zig build gen-models -- --help
```

`gen-models` keeps `cost`/`capabilities`/`knowledge_cutoff` from the
hand-curated built-in entries (or from `--base PATH`) and lets the
live endpoint override `display_name`/`context_window`/`max_output`
where it returns them. Output is sorted by id for diff-friendly
regeneration.

OpenAI's `/v1/models` returns ~120 models; gen-models filters down
to chat-completion-compatible ids by default (drops `dall-e-*`,
`whisper-*`, `text-embedding-*`, `*-audio*`, `*-realtime*`,
`*-search-*`, etc.). Pass `--openai-include-all` to keep them.

Ollama uses its native `GET /api/tags` endpoint (not OpenAI-compat);
override the base URL with `--ollama-url` or `OLLAMA_HOST`. Entries
are mapped to `api: "openai-compatible-gateway"` so franky can drive
them via `--base-url http://localhost:11434/v1` at runtime. After
`/api/tags`, gen-models follows up with `POST /api/show` per model
to extract the real context window (from
`model_info.<arch>.context_length`) and capability flags (tools,
vision, embedding). Use `--ollama-shallow` to skip the per-model
calls and fall back to tags-only data.

## What's deferred (post-1.0)

The complete deferred-work catalog lives in
[`docs/spec/v2.md`](docs/spec/v2.md). Highlights:

- **`franky-do` Slack-bot** sibling project (post-1.0 per §O).
  Pattern + `--role plan` posture documented in
  [`docs/reference/sandbox.md`](docs/reference/sandbox.md).
- **`franky-pods` vLLM CLI** sibling project.
- **Extension Tier-2 / Tier-3** (`.so`/`.dylib` / Wasm). Tier-1
  static-module loading ships; Tier-2/3 need a versioned ABI + sandbox.
- **Multi-tenant proxy auth.** `--mode proxy` is single-user, binds
  127.0.0.1; team deployments need bearer-token middleware.
- **`io.concurrent` backend.** `std.Io` threaded backend covers
  everything; the green-threads variant is a Zig-stable migration, not
  a correctness gap.

For a complete, dated history of what shipped at each version see the
"What shipped" table in [`docs/spec/v1.md`](docs/spec/v1.md).

## Troubleshooting

### `zig build` fails with truncated-ELF errors on shared mounts

**Symptom:** `zig build` errors on `.zig-cache/o/<hash>/build_zcu.o` with a
truncated-ELF message. `zig test` and `zig run` succeed.

**Cause:** Your checkout is on a **virtiofs / FUSE shared mount** (common
in VM-backed dev sandboxes). virtiofs with the `keep_cache` mount flag
races on large (>10 MB) writes.

**Fix:** Redirect Zig's cache to a non-virtiofs path:

```sh
export ZIG_LOCAL_CACHE_DIR=/tmp/franky-zig-cache
export ZIG_GLOBAL_CACHE_DIR=/tmp/franky-zig-global
zig build
```

On a normal filesystem (ext4, APFS, tmpfs, overlay) plain `zig build` / `zig build test` works unchanged.

### `zig build test` fails on macOS with Homebrew Zig 0.16

**Symptom:** `franky-test` fails with no obvious assertion (the
test runner's `--listen=-` framing hides the stack trace) on
macOS where `zig version` reports `0.16.0` from
`/opt/homebrew/Cellar/zig/0.16.0/`.

**Cause:** `build.zig.zon` requires `0.17.0-dev`. Several stdlib
shapes the test code relies on (`std.testing.tmpDir` layout,
error-set switch exhaustiveness, `std.Io.Dir` / `std.process.Init`
APIs) drift between 0.16 and 0.17-dev. Some tests slip through
the build but fail at runtime with brittle assertions.

**Fix:** install a 0.17-dev toolchain.

```sh
brew uninstall zig
brew install zig --HEAD            # tracks master ≈ 0.17-dev
zig version                        # should print 0.17.0-dev.<commit>
```

Or grab a dated 0.17-dev tarball from
<https://ziglang.org/download/>. The repo is built and tested
against `0.17.0-dev.87+9b177a7d2` and newer.

Note for contributors writing new tests: prefer
state-machine-style assertions over filesystem round-trips when
the behavior under test is observable from in-process state.
The `ai/log.zig` v1.13.0 tests are a worked example —
`std.testing.tmpDir`'s on-disk path varies enough across
(Zig version × OS) that read-back-and-substring-match tests
have a long tail of platform-specific failures.

## Deep codebase analysis (2026-07-03)

A comprehensive automated audit of every module in the source tree was performed.

### 🔴 Critical issues found

1. **Proxy subscriber slot leak** (`src/agent/proxy.zig`) — When a client disconnects without sending FIN/RST (browser background tab, network blip), `fanOutLocked` sets `sub.closed = true` but does **not** shut down the read side of the socket. The reader thread stays blocked on `readVec`, the `defer removeSub` never runs, and after ~32 cycles (`max_subs = 32`) all slots are exhausted. **Fix:** shut down the read side of the socket when flagging `sub.closed`.

2. **Object store `sweep` can cause silent data loss** (`src/coding/object_store.zig:102-115`) — `sweep()` relies on an externally-supplied `keep` list of SHA-256 hashes. If the caller passes an incomplete list, referenced blobs are deleted. **Fix:** verify every `Ref` in the transcript is in the `keep` list before deletion.

3. **Grep regex `\b` assertions reject valid model output** (`src/coding/tools/grep.zig`) — The regex engine uses ECMAScript which doesn't support `\b`. Models that emit word-boundary assertions receive `grep_bad_regex`. **Fix:** pre-process patterns or switch to a richer regex engine.

### 🟡 High-severity issues

4. **`catch return` voids `errdefer` chains** (`agent/loop.zig`, `agent/agent.zig`) — Pattern `const x = fn() catch return; errdefer cleanup(x);` makes the `errdefer` dead code. **Fix:** convert to `!void` wrapper so `errdefer` fires on error path.

5. **`freeSessionHeader` is fragile** (`src/coding/session.zig:147-151`) — Adding a new owning-string field to `SessionHeader` silently leaks unless `freeSessionHeader` is updated. **Fix:** use compile-time reflection or add a comptime assertion.

6. **No end-to-end tests for the four run modes** (`src/coding/modes/`) — `print.zig`, `interactive.zig`, `rpc.zig`, `proxy.zig` have zero mode-level integration tests.

### 🟡 Medium-severity issues

7. **`nowMillis()` returns 0 on error** (`src/ai/stream.zig:36-53`) — Degrades timing-dependent guards (stuck detector, SSE handler-stall timeout). Rare non-Linux POSIX edge case.

8. **Compaction `replaceSpanWithSummary` uses manual `memcpy`** (`src/coding/compaction.zig:556-566`) — Array splicing is brittle; a single off-by-one corrupts the transcript silently.

9. **Partial JSON parser has no dedicated test coverage** (`src/ai/partial_json.zig`) — Complex state machine for streaming tool-call args with no focused test suite.

### 🟢 Low-severity

10. **`SubAgent final_text` occasionally empty** — Sub-agent calls complete without `final_text` despite full transcripts.
11. **DeepSeek tool-call JSON parsing** — Non-standard JSON format from DeepSeek models causes parse failures.
12. **`end_turn` not emitted by smaller models** — Causes infinite tool-call loops; guardrail mitigations exist but the problem persists.

### ✅ Strengths confirmed by deep audit

- **Zero external dependencies** — entire framework is pure Zig.
- **Thorough memory management** — every allocation paired with `defer`/`errdefer`.
- **Mature threading model** with three-level cancellation.
- **Comprehensive error taxonomy** with retryability metadata.
- **Atomic file operations** throughout (tempfile + rename).
- **Permission system** with 4 role tiers, tool-level gates, bash verb fingerprinting.
- **Spec-driven development** with automated cross-reference checking.
- **7 LLM providers** with unified streaming interface.
- **881 tests with leak detection** on every run.
- **Guardrails** for unattended operation (stuck detection, compilation check, finish_task).

### Recommended next steps

1. Fix the proxy subscriber leak — highest priority.
2. Fix grep regex `\b` handling.
3. Audit all `catch return` patterns for voided `errdefer` chains.
4. Add mode-level integration tests.
5. Harden `freeSessionHeader` with compile-time field iteration.
6. Add `sweep` completeness assertion.
7. Cover `partial_json.zig` with a dedicated unit-test suite.
8. Investigate the sub-agent empty-final-text edge case.
9. Consider switching the regex engine.

## License

See the repository root for license information.
