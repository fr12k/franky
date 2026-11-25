# A2UI support in franky proxy web mode — implementation plan

Status: **PoC implemented** (2026-07). Plan below kept for context; see §8 for what actually shipped.

## 1. A2UI v1.0 in a nutshell

A2UI (Agent-to-User Interface, a2ui.org, current spec **v1.0**, Nov 2025, updated Jun 2026)
is an open JSON-based streaming protocol for *generative UI*. The agent declaratively
describes UI surfaces; the client renders them with **native catalog components** — no
untrusted code executes client-side.

### Agent → Renderer stream (unidirectional, JSONL/SSE-friendly)

Every message validates against the `agent_to_renderer` envelope, exactly one key:

| Message | Purpose |
|---|---|
| `createSurface` | Initialize a surface (`surfaceId`, `catalogId`, optional `sendDataModel`) |
| `updateComponents` | Adjacency-list component definitions (`id`, `component`, `children`/`child`, props with `@path`/`@call` dynamic bindings) |
| `updateDataModel` | Populate/patch the reactive data model (RFC 6901 JSON Pointer paths) |
| `deleteSurface` | Tear down a surface |
| `callRendererFunction` / `agentFunctionResponse` | Optional bidirectional function RPC (new in v1.0) |

### Renderer → Agent

- `action` messages: `name`, `surfaceId`, `sourceComponentId`, `timestamp`,
  resolved `context` (with `@path` bindings resolved renderer-side).
- Validation errors (`UNALLOWED_PARENT`, `UNALLOWED_CHILD`, `EXPRESSION_ERROR`, …).
- Optional `rendererFunctionResponse`.

### Key model traits

- **Adjacency-list UI tree** — flat component list referencing children by ID;
  streaming-friendly (progressive rendering as messages arrive).
- **Data binding** via JSON Pointers: absolute `/path`, or relative inside template
  scopes (container `children: {path, componentId}` creates a child scope per item).
- **Two-way binding is renderer-local** — inputs mutate the local model immediately;
  nothing reaches the agent until an `action` fires.
- **Basic Catalog** (`Text`, `Button`, `Row`, `Column`, `List`, `TextField`,
  `CheckBox`, `Card`, …) with swappable custom catalogs; catalogs must use
  `ComponentId` / `ChildList` schema refs so validators can check structural links.
- **Transport-decoupled** — official bindings: AG-UI, A2A, MCP; any HTTP/SSE/WS
  channel is allowed.

Spec references (pin locally before implementation):

- https://a2ui.org/specification/v1.0-a2ui.md
- https://a2ui.org/specification/v1.0/schemas/ (`agent_to_renderer.json`,
  `renderer_to_agent.json`, `common_types.json`, `catalogs/basic/catalog.json`)
- https://a2ui.org/specification/v1.0-basic-catalog-implementation-guide.md

## 2. franky proxy mode — current state

`src/coding/modes/proxy.zig` already provides:

- `GET /events` — SSE stream of internal `AgentEvent`s
  (`event: <kind>\ndata: <json>`), replay ring + htmx hx-sse HTML variant (`src/coding/sse.zig`).
- `POST /prompt`, `POST /command` (slash dispatch), `POST /abort`,
  `GET /transcript`, `GET /health`.
- Built-in web UI embedded via `@embedFile` (`src/coding/modes/web/`: index.html,
  app.js, style.css, htmx, prism).
- Single-session model; `AgentEvent` union (`turn_start`, `message_update` deltas,
  `tool_execution_*`, `tool_permission_request`, `provider_retry`, …) fanned out to
  all subscribers.

So the agentic plumbing (sessions, tools, SSE fan-out, replay, slash commands,
permission gate) exists with a *custom* chat UI. Missing for A2UI: the **protocol
layer** — A2UI envelopes, surface/component/data-model state, `action` intake, and
an A2UI renderer client.

## 3. Architecture options

- **Option A — sidecar endpoint (recommended, minimal risk).** Add
  `GET /a2ui/events` + `POST /a2ui/action` alongside the existing API. Existing web
  UI and SSE stream untouched; A2UI is an additional projection.
- **Option B — replace the built-in web UI with an A2UI renderer.** Bigger long-term
  win (whole UI becomes generative: permission prompts, tool cards, forms), but
  requires building/porting a full JS A2UI renderer and migrating every UI feature.

Plan assumes **A, structured so it can evolve into B**.

## 4. Work items

### 4.1 A2UI protocol module (`src/coding/a2ui/`)

- Zig types mirroring the v1.0 schemas: envelope union
  (`createSurface | updateComponents | updateDataModel | deleteSurface |
  callRendererFunction | agentFunctionResponse`), `Component`, `ChildList`,
  `DynamicString`/`DynamicBoolean` (`@path`/`@call`), inbound action/error messages.
- Pin the official JSON Schemas into `docs/spec/a2ui/`; add tests validating emitted
  envelopes against the schema (or against the spec's golden JSONL examples).

### 4.2 Surface/session manager (`a2ui/surfaces.zig`)

- Surface registry: `surfaceId` → { adjacency list, data-model tree, catalogId }.
- Server-side data-model store with JSON-Pointer set/merge (needed to resolve
  `@path` when composing updates and to honor `sendDataModel` metadata).
- Progressive-streaming buffer: queue `updateComponents`/`updateDataModel` deltas
  per surface; serialize onto SSE.

### 4.3 Translator: `AgentEvent` → A2UI (`a2ui/translate.zig`)

The core design work. Initial mapping:

| franky `AgentEvent` | A2UI emission |
|---|---|
| session start | `createSurface{surfaceId:"chat", catalogId:basic}` + `updateComponents` for chat shell (List of message cards, TextField + Send Button bound to `/input`) |
| `message_start` / `message_update` (text delta) | `updateDataModel` appending to `/messages/<i>/text` (renderer `Text` bound via `@path` updates reactively) |
| `tool_execution_start` / `_end` | `updateComponents` adding a tool-card component (custom catalog: `ToolCall`, `CodeBlock`, `Diff`) + `updateDataModel` with args/result |
| `tool_permission_request` | `updateComponents` rendering a permission form (Buttons `allow_once` / `allow_always` / `deny`, `action.event.context` carries `call_id`) |
| `turn_end` / `agent_error` | `updateDataModel` status field (`/turnState = idle|error`) |

### 4.4 Inbound action handling

- `POST /a2ui/action`: parse `renderer_to_agent` envelope; route by `action.name`:
  - `send_prompt` → same path as `POST /prompt`.
  - `permission_decision` → `permissions.PermissionPrompter.resolve(...)`.
  - `abort` → `session.cancel`.
- Slash commands: agent actions from a command-palette component, or keep
  `POST /command` as-is.

### 4.5 Transport endpoint (`proxy.zig` additions)

- `GET /a2ui/events`: SSE with JSONL A2UI envelopes in `data:` frames. Reuse
  `sse.zig` fan-out + replay ring so reloads rehydrate.
- Later: implement the **AG-UI binding** for interop with the off-the-shelf A2UI
  ecosystem (CopilotKit playground, A2UI Composer).

### 4.6 Client renderer

- **6a (fast):** embed the official A2UI Lit/web-components renderer like the current
  `htmx.min.js` assets; surfaces mount in a container div; existing chat panel
  coexists during migration.
- **6b (full control):** bespoke minimal JS renderer (basic catalog + 3–5
  franky-specific components). Zero dependency, sized to franky; much more work.

### 4.7 Custom franky catalog (likely needed)

Basic catalog lacks `CodeBlock`, `Diff`, `ToolCall`, `ThinkingBlock`. Define
`franky_catalog.json` extending basic, following catalog rules (`ComponentId` /
`ChildList` refs, `allowedParents` / `allowedChildren`).

### 4.8 Security & scope notes

- Proxy is unauthenticated and currently binds `0.0.0.0` — unchanged by A2UI; keep
  the documented guidance (TLS-terminating proxy with auth in front).
- A2UI's "no untrusted code" property aligns with franky's sandbox posture: custom
  catalog components are static renderer code, never model-generated.

## 4.9 How the model uses A2UI components (clarified)

The spec's canonical usage is a **prompt–generate–validate loop**, not tool calling:

1. **Prompt**: system prompt includes the A2UI JSON schema **including the component
   catalog**, plus examples of valid A2UI JSONL.
2. **Generate**: the model emits A2UI messages (`createSurface`, `updateComponents`,
   `updateDataModel`, …) as ordinary text/structured output.
3. **Validate**: the host validates against the schema; failures go back to the
   model as a standardized `error` message (`VALIDATION_FAILED` /
   `UNALLOWED_PARENT` / `UNALLOWED_CHILD` + JSON-pointer `path`) so it self-corrects.

Key details:

- Catalogs carry an **`instructions`** field — Markdown design rules explicitly
  meant to *guide LLMs generating layouts*. The catalog file is designed to be
  injected into the prompt (schema + design guidance in one artifact). Google also
  ships this as agent skills (`npx skills add a2ui-project/a2ui`).
- A2UI **functions** (`functionCall`, `callRendererFunction`, `callAgentFunction`,
  `formatString`, validators like `required`/`email`) are **renderer/agent RPCs,
  not LLM tools**. The model only *references* them in generated JSON; they never
  go through the LLM tool-calling API.
- Exposing `emit_a2ui` as a **real LLM tool** is an optional host-side delivery
  mechanism (API-enforced structure, fewer malformed outputs), but costs a tool
  slot and round-trips; the spec's reference loop is plain generation + validation.

Consequence for franky — two distinct paths:

- **Translator path (Option A, §3):** franky's Zig code maps `AgentEvent`s → A2UI
  deterministically. **The model never sees A2UI; no prompt changes.** Cheap,
  reliable MVP. UI is generative from the client's view but hard-coded agent-side.
- **True generative UI (endgame):** the model itself emits A2UI ("show a form to
  configure X", custom dashboards). Requires:
  1. Inject franky catalog JSON + `instructions` + examples into the system prompt
     — conditionally: only in proxy mode, and only when the renderer advertised
     `supportedCatalogIds`.
  2. Validation step in franky before forwarding model output to `/a2ui/events`,
     feeding the spec's standard `error` message back into the conversation.
  3. Optionally an `emit_ui` tool (envelope schema as input schema) for
     API-enforced structure instead of free generation.

## 5. Effort estimate

| Item | Size |
|---|---|
| 4.1 Schema types + validation tests | S–M (2–3 d) |
| 4.2 Surface/data-model manager | M (3–4 d) |
| 4.3 Event translator (core) | M–L (4–6 d, iterative) |
| 4.4 Action inbound + permission bridge | S (1–2 d) |
| 4.5 SSE endpoint wiring (reuse sse.zig) | S (1 d) |
| 4.6a Official renderer embed | S (1–2 d) |
| 4.6b Custom renderer | L (1–2 wk) |
| 4.7 Custom catalog | S (1 d) |

**MVP** (Option A + 6a + basic catalog only; chat text streaming + prompt/abort +
permission form): ~2 weeks.
**Full parity** with current web UI (tool cards, diffs, transcript rehydrate, slash
palette, cost display): ~4–6 weeks.

## 6. Suggested sequencing

1. 4.1 + 4.5 skeleton: emit a hard-coded `createSurface` + static form; render it
   with the official renderer (proves transport + renderer choice end-to-end).
2. 4.2 + 4.3 for the text-streaming path (prompt → streamed message).
3. 4.4 actions incl. permission bridge (closes the interactive loop).
4. 4.7 custom catalog for tool/diff cards; migrate remaining UI features.
5. (Optional, post-MVP) True generative UI per §4.9: conditional catalog
   injection into the system prompt, output validation with `error` feedback loop,
   optional `emit_ui` tool.

## 8. PoC — what shipped

Flag + settings gated, **off by default**: `--a2ui` / `--no-a2ui` CLI flags,
`tools.a2ui.enabled` in settings.json. Files:

- `src/coding/a2ui.zig` — A2UI session state (surface components + data model),
  envelope validation (PoC basic catalog: Column, Row, Text, Button, TextField;
  `@path` bindings; `@call`/template ChildLists rejected), deep-merge data model,
  SSE broadcast, system-prompt block. Unit-tested.
- `src/coding/tools/a2ui_render.zig` — `a2ui_render` tool: applies an array of
  envelopes in order; validation failures return the spec's standard error
  format (`VALIDATION_FAILED` / `UNALLOWED_*` / `EXPRESSION_ERROR` + JSON
  pointer path) as tool errors so the model self-corrects. Unit-tested
  (execute-path e2e: valid → state; invalid → tool error).
- `src/coding/modes/web/a2ui.html` — self-contained vanilla-JS renderer page
  (`/a2ui.html`): adjacency-list rendering, RFC 6901 `@path` resolution,
  renderer-local two-way binding, Button actions → `POST /a2ui/action`,
  EventSource with snapshot catch-up.
- `src/coding/modes/proxy.zig` — endpoints (only when enabled):
  `GET /a2ui.html`, `GET /a2ui/events` (SSE; synthetic `a2ui_snapshot` frame on
  connect / stale Last-Event-ID), `POST /a2ui/action` (appends
  `[A2UI action] name=… context=…` as a user message and runs a normal turn).
  Tool registration + system-prompt injection happen at session init.
  `FRANKY_FAUX_LOG_TOOLS=1` makes the faux provider log offered tools for e2e.

Verified end-to-end with the faux provider: endpoints gated correctly (404 /
200), `a2ui_render` appears in the model's tool list + A2UI block in the
system prompt, `/a2ui/action` round-trips into the transcript and produces an
agent turn, invalid action payloads → 400.

PoC scope cuts (vs. full plan): one fixed surface `"main"` (createSurface
optional/idempotent), snapshot instead of a replay ring, no `emit_ui`
structured-output tool (the model emits via the regular tool-call channel).

### 8.1 Round 2 (2026-11) — permission-form integration (§4.4) + translator seed (§4.3)

- **Permission forms (§4.4 closed).** `tool_permission_request` events are
  projected into the A2UI surface as a host-injected `Card`
  (`a2uiProjectPermissionRequest` in `proxy.zig`): tool name + raw args as
  title/subtitle, a "Remember this decision" `CheckBox` (two-way bound to
  `/perm/<call_id>/remember`), and Allow/Deny `Button`s firing the reserved
  `permission_decision` action. `POST /a2ui/action` intercepts
  `permission_decision` and resolves the pending prompt via
  `PermissionPrompter.resolve` (`allow_once`/`always_allow`/`deny_once`/
  `always_deny` from decision+remember) — the action never reaches the LLM.
  After resolving, the card is removed from the surface. Proxy-level tests
  cover the full round-trip (request → card → decision → resolution +
  card cleanup) and the no-pending-prompt 409 path.
- **Host-side projection API (§4.3 seed).** `a2ui.zig` gained
  `upsertComponents` (validate + merge into the adjacency list by id) and
  `removeComponents` (drop ids, prune dangling child references), both
  broadcast as regular `updateComponents` envelopes. This is the mechanism
  the future `AgentEvent` → A2UI translator will use; the permission
  projection is its first consumer.
- **Catalog: +`CheckBox`, +`Card`** (validation + vanilla-JS rendering,
  two-way boolean binding for `checked`).
- **Renderer convergence.** `updateComponents` is now upsert-by-id on both
  server (`upsertComponents`) and renderer (was full-replace), so
  host-injected UI survives the model's full-tree re-renders; components
  not reachable from `root` (e.g. permission cards) render after the
  model tree. Snapshots now carry `surfaceId`.

Remaining scope cuts after round 2: single surface, snapshot instead of a
replay ring, no `emit_ui` tool, no per-delta streaming text (open question
§7.2), no AG-UI binding (open question §7.1).

## 7. Open questions (resolve before execution)

1. Goal = **interoperability** (external A2UI clients connect to franky) or
   **replacing franky's web UI** with generative UI? Decides A vs B and whether the
   AG-UI binding matters.
2. Streaming text via per-delta `updateDataModel` is chattier than current SSE text
   deltas — acceptable, or add a franky-catalog `StreamingText` component with
   append semantics?
3. Renderer choice: official Lit components vs. bespoke minimal JS renderer?
4. JSON-Schema validation in Zig: acceptable dependency, or validate only against
   golden fixtures in tests?
5. Translator-only (model never sees A2UI) vs. true generative UI (model emits
   A2UI per §4.9)? The translator MVP doesn't foreclose either, but the prompt
   token cost of catalog injection and the validation-feedback loop design depend
   on the answer.
