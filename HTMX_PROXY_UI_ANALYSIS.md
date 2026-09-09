# Analysis: Migrating the franky Proxy Web UI to htmx 4

| | |
|---|---|
| **Status** | Analysis (not a proposal to execute) |
| **Branch** | `rfc/htmx-proxy-ui` |
| **Scope** | `src/coding/modes/web/` (the built-in web UI) + `src/coding/modes/proxy.zig` (the SSE/HTTP server) |
| **Created** | 2025-09-09 |

## 1. Summary

This document analyzes whether the franky proxy-mode web UI — a
3403-line vanilla-JS single-page chat client (`src/coding/modes/web/app.js`)
driven by a 5782-line SSE server (`src/coding/modes/proxy.zig`) — could be
migrated to htmx 4 the same way franky-box's admin UI was.

**Bottom line: a full migration is technically possible but not
recommended.** Unlike franky-box (6 read-only tables + 1 form), the franky
web UI is a **real-time streaming chat client** whose core value is
incremental, in-place DOM mutation driven by ~12 SSE event types. htmx 4
ships an `hx-sse` extension that can stream HTML fragments over SSE and
swap them in, so the *mechanics* exist — but the current `app.js` is doing
things htmx is not designed to do well (per-token streaming markdown
rendering into a growing "live" block, tool-card state machines, sub-agent
overlays, a slash-command palette with fuzzy completion, prompt-history
navigation). Moving that to htmx would either (a) require sending
pre-rendered HTML fragments per token (huge server-side markdown renderer
+ big SSE bandwidth increase) or (b) keep a substantial JS layer for the
streaming-render parts, at which point htmx buys little.

A **partial migration** of the *non-streaming* surfaces (sidebar/session
list, design-docs panel, role/usage pills, slash-command dispatch) is
attractive and low-risk, and is the recommended path if any htmx adoption
is pursued. The streaming conversation pane should stay vanilla JS +
SSE/EventSource.

## 2. Current architecture

### 2.1 Server (`src/coding/modes/proxy.zig`, 5782 lines)

A thread-per-connection HTTP server. Static assets are `@embedFile`-d at
compile time (`web/index.html`, `web/app.js`, `web/style.css`,
`web/prism.js`, `web/prism-tomorrow.css`). The API surface:

| Method | Path | Returns | Purpose |
|---|---|---|---|
| GET | `/` | HTML shell | the SPA page |
| GET | `/app.js`, `/style.css`, `/prism.js`, `/prism-tomorrow.css` | static | embedded assets |
| GET | `/events` | `text/event-stream` | **the SSE stream** — the core of the UI |
| POST | `/prompt` | `200 {"ok":true}` | submit a user message, run one turn |
| POST | `/abort`, `/interrupt`, `/restart` | JSON | control the loop |
| POST | `/command` | JSON `{ok,output,sideEffect?,data?}` | slash commands |
| POST | `/permission/resolve` | JSON | answer a tool-permission prompt |
| GET | `/transcript` | JSON | rehydrate after reload (`renderTranscriptForUi`) |
| GET | `/sessions`, `/session`, `/session/new`, `/session/activate` | JSON | session management |
| GET | `/sessions/<id>/transcript` | JSON | per-session transcript |
| GET | `/role`, `/usage` | JSON | role + token-usage pills |
| GET | `/design-docs`, POST `/design-docs/archive` | JSON | design-docs panel |

SSE frames are hand-written strings: `event: <kind>\ndata: <json>\n\n`,
with `id:` for replay (the server has a replay ring keyed by `Last-Event-ID`).

### 2.2 Client (`src/coding/modes/web/app.js`, 3403 lines, 118 functions)

A dependency-free SPA. The architecture is:

- **`EventSource('/events')`** is the single source of truth. ~12 named
  event listeners dispatch to render functions:
  `turn_start`, `turn_end`, `message_start`, `message_update`,
  `message_end`, `tool_execution_start`, `tool_execution_end`,
  `tool_execution_update`, `tool_permission_request`, `agent_error`,
  `agent_interrupted`, `session_switched`, `ping`.
- **Streaming markdown renderer** (lines 1-211): a hand-rolled
  CommonMark subset (headings, fences, inline code, bold/italic, links,
  lists, tables) that renders incrementally. This is the heart of the UI —
  assistant text arrives as `message_update` deltas (`{deltaKind:"text",
  delta:"...", blockIndex:N}`) and is appended into a growing "live"
  block, re-rendered per delta.
- **Prism syntax highlighting** (prism.js, vendored, 3357 lines) runs
  after each markdown render pass.
- **Tool cards**: a state machine per `callId`. `tool_execution_start`
  opens a card; `tool_execution_update` appends sub-agent progress;
  `tool_execution_end` finalizes with result/error. Sub-agent cards get
  their own panel + a full-screen overlay.
- **Permission overlay**: `tool_permission_request` renders a modal; the
  user's choice POSTs to `/permission/resolve`.
- **Composer**: a `<textarea>` with Enter-to-send, prompt history
  (localStorage ring), and a slash-command palette with fuzzy filtering.
- **Sidebar**: session list (`/sessions`), new/activate session.
- **Status line**: live elapsed-time + token usage (`/usage`).
- **Design-docs panel**: list/archive design documents (`/design-docs`).

### 2.3 What's JSON vs SSE

- **SSE** (`/events`): all real-time conversation events (assistant text
  deltas, tool progress, errors, turn lifecycle). This is 90% of the UI's
  dynamism.
- **JSON fetches**: session list, transcript rehydration, role/usage
  pills, design docs, slash-command results, permission resolve. These
  are request/response, not streaming.

## 3. Why this is not like franky-box

franky-box's admin UI was a **request/response CRUD dashboard**: click a
nav link → fetch JSON → render a table. htmx is purpose-built for that
pattern (server emits an HTML fragment, htmx swaps it in). The win was
deleting the duplicated JSON+HTML rendering.

franky's web UI is a **streaming chat client**. The dominant interaction
is: user sends a prompt → the server emits a *stream* of incremental
events → the client *accumulates* them into a growing DOM tree with
live markdown re-rendering. This is not a swap-in-a-fragment pattern; it
is append-to-a-live-region-with-state. Converting it means the server must
emit rendered HTML fragments per event, and the client must still manage
the "live block" accumulation, the tool-card state machine, and the
sub-agent overlay wiring.

| Dimension | franky-box admin | franky web UI |
|---|---|---|
| Interaction | request/response (click → table) | streaming (prompt → token deltas) |
| Data format to browser | JSON | SSE JSON events |
| Rendering | build HTML from JSON in JS | accumulate deltas into live DOM + re-render markdown per delta |
| # of "views" | 6 tables + 1 form | 1 conversation pane + 5 side panels |
| Client JS | 270 LoC (18 fns) | 3403 LoC (118 fns) |
| State machine | none | tool cards, sub-agent overlays, permission modals, prompt history |
| htmx fit | excellent (textbook) | poor for the streaming core, okay for the side panels |

## 4. htmx 4 `hx-sse` extension — what it can and can't do

htmx 4 moved SSE into an opt-in extension (`hx-sse`). It supports:

- **`hx-sse:connect="/events"`** — open a persistent SSE connection.
- **Unnamed events swap into the target**: `data: <p>hello</p>` → htmx
  swaps `<p>hello</p>` per `hx-swap`/`hx-target`.
- **`hx-swap-oob`** for multi-element updates: one event can carry
  `<div id="status" hx-swap-oob="true">…</div>` to update a separate region.
- **`<hx-partial hx-target="#feed">`** for targeting other elements.
- **Named events** (`event: progress\ndata: 50`) dispatch as DOM events
  handleable via `hx-on`.
- **`id:` + `Last-Event-ID`** replay — matches the existing server replay
  ring, so reconnect semantics survive.
- **`hx-swap="beforeend"`** accumulates chunks (for token streaming).

**What it does NOT give you for free:**

1. **Incremental markdown re-rendering.** The current UI receives a text
   delta and re-runs the markdown renderer over the accumulated block,
   then re-highlights with Prism. With htmx, the server would have to
   render markdown → HTML per delta and send the full re-rendered block as
   each SSE frame. That means: (a) a Zig-side markdown renderer (none
   exists; the markdown renderer is in JS today), (b) ~5-20× the SSE
   bandwidth (full HTML block per token vs a small `{delta}` JSON blob),
   and (c) Prism highlighting would need to re-run on the client after
   each swap (htmx doesn't do syntax highlighting). You'd keep a JS hook
   (`htmx:after:swap`) to call Prism — so JS doesn't go away.
2. **Tool-card state machine.** A tool call is opened by
   `tool_execution_start`, mutated by N `tool_execution_update` events,
   and finalized by `tool_execution_end`. htmx swaps are idempotent
   replacements; modeling an append-only log + a status badge + a
   collapsible result panel requires either out-of-band swaps targeting
   multiple sub-elements per event, or a server that emits the *entire*
   tool card re-rendered on every update. The latter is simpler but
   re-sends stable HTML (the tool name, args) on every progress tick.
3. **Sub-agent overlay.** A separate full-screen conversation view for a
   sub-agent, opened on demand, fed by `tool_execution_update` events
   keyed by the parent call id. This is a second SSE-derived live region
   with its own accumulation logic — not a fragment swap.
4. **Slash-command palette with fuzzy completion.** This is a keyboard
   UX widget (type `/`, filter commands, arrow-navigate, Enter). htmx
   can fetch the filtered list via `hx-get` on `keyup`, but the debouncing,
   arrow navigation, and selection highlighting are JS interactions
   htmx doesn't replace.

## 5. Migration scenarios

### 5.1 Full migration (not recommended)

Convert everything: the SSE stream emits HTML fragments; htmx swaps them
in; the side panels become htmx fragments; the composer `hx-post`s.

**Cost:**
- Write a Zig markdown renderer (~400-600 lines to match the current JS
  subset) OR keep the JS renderer and send text deltas, at which point
  htmx isn't doing the rendering.
- Convert `renderTranscriptForUi` from JSON to HTML (transcript
  rehydration).
- Rewrite the SSE frame emitters to produce HTML fragments per event
  instead of JSON.
- Convert tool-card state machine to per-event full-card HTML re-renders
  (simpler) or multi-target OOB swaps (more complex).
- Keep JS for: Prism re-highlighting after swap, slash-command palette
  keyboard nav, prompt-history, the sub-agent overlay accumulation.
- Net: `app.js` shrinks by maybe ~1000-1500 lines (the JSON-fetch +
  table-render + session-list parts), but a comparable amount of Zig is
  added (markdown renderer + HTML fragment builders). `proxy.zig` grows.
- SSE bandwidth rises because HTML fragments are larger than JSON deltas
  for the streaming-text path (full re-rendered markdown block per token
  vs `{"delta":"foo"}`).

**Benefit:** removes the JSON/HTML duplication for the side panels and
transcript. But the streaming core still needs JS, so the "zero JS" win
from the franky-box migration is unattainable here.

**Verdict:** the complexity and risk are high, the net-line reduction is
small or negative, and the streaming UX may regress (bandwidth, highlight
flicker). Not recommended.

### 5.2 Partial migration of the side panels (recommended if pursued)

The non-streaming surfaces map cleanly to htmx:

| Surface | Current | htmx |
|---|---|---|
| Sidebar session list | `GET /sessions` → JSON → render `<li>` | `hx-get="/sessions" hx-target="#session-list"` → server emits `<li>` fragments |
| New/activate session | `POST /session/new` → JSON → reload list | `hx-post` → server emits refreshed `<ul>` |
| Role pill | `GET /role` → JSON → set text | `hx-get="/role" hx-target="#role-pill" hx-trigger="load, session_switched from:body"` |
| Usage pill | `GET /usage` → JSON → set text | `hx-get="/usage" hx-target="#model-pill" hx-trigger="load, every 10s"` |
| Design-docs panel | `GET /design-docs` → JSON → render rows | `hx-get` → server emits rows |
| Slash-command dispatch | `POST /command` → JSON → toast | `hx-post` → server emits a toast fragment |
| Permission resolve | `POST /permission/resolve` → JSON | `hx-post` form → server emits confirmation fragment |
| Transcript rehydration | `GET /transcript` → JSON → render | `hx-get` → server emits the conversation HTML |

These are all request/response patterns identical to franky-box. The
server already has the data; the JSON builders become HTML builders.
Estimated reduction: ~600-900 lines of `app.js` (the fetch/render code
for these panels) for ~200-300 lines of Zig HTML builders. Net
~400-600 lines removed, and the side panels gain progressive enhancement.

**The streaming conversation pane stays vanilla JS + EventSource.** This
is the key boundary: htmx owns the request/response panels; vanilla JS
owns the streaming core. The two coexist (htmx 4 is designed to coexist
with arbitrary JS).

### 5.3 No migration (also valid)

The current architecture works, has no duplicated rendering (the server
emits JSON events; the browser is the only renderer), and the streaming
UX is good. The franky-box migration's motivation (duplicated rendering,
two escapers, a hand-rolled JSON scanner) does not apply here — there is
no server-side HTML/JSON duplication to eliminate. The server emits
SSE/JSON; the browser renders. That's a clean single-renderer design
already.

## 6. Recommendation

1. **Do not pursue a full migration.** The streaming chat core is a poor
   fit for htmx and the migration would add a Zig markdown renderer,
   increase SSE bandwidth, and still require substantial JS.
2. **If a code-reduction goal exists for the web UI**, pursue the
   **partial migration (§5.2)** of the side panels only. It's low-risk,
   mechanically the same as the franky-box migration, and yields a real
   net reduction. The streaming conversation pane, composer, tool cards,
   sub-agent overlay, and slash palette stay vanilla JS.
3. **If no code-reduction pressure exists**, the current design is fine
   as-is. It is already a single-renderer (browser) design with no
   server-side HTML duplication to eliminate — the primary motivation
   that drove the franky-box migration does not apply.

## 7. Why the franky-box rationale does not transfer

| franky-box motivation | Applies to franky web UI? |
|---|---|
| Duplicated rendering (server JSON + browser HTML) | **No** — server emits JSON/SSE; browser is the sole renderer |
| Duplicated escaping (server `jsonString` + browser `escapeHtml`) | **No** — only the browser escapes (for HTML) |
| Hand-rolled JSON input scanner (120 LoC) | **No** — `/prompt` is `text/plain`, `/command` is text; no JSON input parsing on the server |
| No progressive enhancement (JS-only nav) | **Partially** — the side panels are JS-only, but the conversation pane is inherently JS-only (streaming) |
| Token in a JS-readable cookie | **No** — proxy mode has no auth/cookie model in the web UI |
| JS-only mobile nav | **Minor** — the sidebar toggle is JS, could be `<details>` |

The franky-box migration's wins came from eliminating *server-side*
duplication. The franky web UI has no server-side HTML generation to
eliminate — it's a thin SSE/JSON emitter. htmx would *add* server-side
HTML generation, not remove duplication.

## 8. Open questions (only if §5.2 is pursued)

1. **Session lifecycle events**: the sidebar refreshes on
   `session_switched` SSE events. htmx can trigger off named SSE events
   (`hx-trigger="session_switched from:body"`), but the event must be
   dispatching as a DOM event. Verify the `hx-sse` extension surfaces
   named events to `hx-trigger` or whether a small `hx-on` bridge is
   needed.
2. **Transcript rehydration as HTML**: `renderTranscriptForUi` currently
   emits JSON. An HTML version would need to render the full message
   history (text + thinking + tool calls) — a big builder. Is it worth it
   vs keeping the JS rehydration (which already works)?
3. **Bundle**: htmx 4 core is ~50 KB; `hx-sse` extension adds more. The
   current UI ships ~0 JS framework (only prism.js + app.js). Adding
   htmx reverses the "zero dependency" stance noted in `app.js` line 9.

## 9. References

- htmx 4 `hx-sse` extension: https://four.htmx.org/extensions/hx-sse
- htmx 4 SSE migration (from 2.0): https://four.htmx.org/extensions/hx-sse (migration notes)
- Current web UI: `src/coding/modes/web/app.js` (3403 LoC, 118 fns)
- Current SSE server: `src/coding/modes/proxy.zig` (5782 LoC)
- franky-box htmx migration (for comparison): `franky-box` repo, branch `rfc/htmx-admin-ui`