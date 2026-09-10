# Analysis: Migrating the franky Proxy Web UI to htmx 4 (revised)

| | |
|---|---|
| **Status** | Analysis (revised after re-reading hx-sse docs) |
| **Branch** | `rfc/htmx-proxy-ui` |
| **Scope** | `src/coding/modes/web/` (the built-in web UI) + `src/coding/modes/proxy.zig` (the SSE/HTTP server) + `src/agent/wire.zig` (event encoder) + `src/coding/sse.zig` (frame renderer) |
| **Created** | 2025-09-09 |
| **Revised** | 2025-09-09 |

## 1. Summary (revised)

**Yes — htmx 4's `hx-sse` extension can handle the SSE event flow and would
dramatically simplify the client side.** My first analysis was too
pessimistic: I underweighted that a single unnamed SSE event can carry
HTML with `hx-swap-oob` targeting *any* element on the page, with zero
client-side event listeners. Re-tracing the 12 event types against this
mechanism, most of the 3403-line `app.js` event-dispatch + render machinery
is eliminable. The server's single `encodeEventJson` function
(`src/agent/wire.zig`, ~130 lines) becomes an `encodeEventHtml` that emits
fragments instead of JSON — one conversion point, not a scatter of
client-side handlers.

**Remaining client-side JS** shrinks to: a markdown renderer (or move it
server-side), Prism re-highlighting after swaps, the slash-command
palette keyboard UX, and prompt-history. The 262-line EventSource
listener block, the 541-line assistant-message + tool-card render
machine, the 422-line sub-agent panel/overlay, the 195-line status line,
the 141-line sidebar, and the 225-line design-docs panel — ~1786 lines —
are largely replaced by `hx-swap-oob` fragments emitted from the server.

**The catch:** the streaming-text path (the `message_update` text deltas)
is the one place htmx's model is a mismatch. htmx swaps replace or
append whole elements; the current UI re-runs a markdown renderer over
the *accumulated* text block per delta. Two options exist (§5.1), both
workable, neither is free.

## 2. The hx-sse mechanism that changes the conclusion

The `hx-sse` extension supports two patterns that make this viable:

### 2.1 Unnamed events with `hx-swap-oob` (the key pattern)

A single SSE frame can carry HTML that updates *multiple arbitrary
elements* on the page, with no client-side JS:

```
HTTP/1.1 200 OK
Content-Type: text/event-stream

data: <div id="status" hx-swap-oob="true">Online</div>
data: <hx-partial hx-target="#feed"><p>New</p></hx-partial>
```

htmx extracts the OOB elements and the `<hx-partial>` targets, swaps
each into its target, and leaves the connection element unchanged
(`hx-swap="none"`). **This is a server-driven multi-element update with
zero JS listeners.** This is exactly what the franky UI's 12 SSE event
handlers do today — manually, in 262 lines of `addEventListener` + render
functions.

### 2.2 Named events for lifecycle signals

Named events (`event: turn_start\ndata: ...`) dispatch as DOM events,
handleable via `hx-on:turn_start="..."` or as a trigger
(`hx-trigger="turn_end from:body"`). This covers the lifecycle signals
(turn start/end, errors) that don't map to "swap HTML into a region."

### 2.3 `id:` + `Last-Event-ID` replay

The server already has a replay ring keyed by `Last-Event-ID`
(`proxy.zig` ~line 2069). hx-sse sends `Last-Event-ID` on reconnect and
the server replays — this is *already implemented* and survives the
migration unchanged.

## 3. Event-by-event trace (the 12 types)

Today: each event fires a named `addEventListener` → parses JSON → calls
a render function that builds/appends DOM. With hx-sse: the server
emits an HTML fragment (unnamed event with OOB targets, or a named
event for lifecycle), and htmx swaps it. No `addEventListener`, no
JSON parse, no client-side DOM builder.

| SSE event | Current JS (lines) | hx-sse approach | JS eliminated? |
|---|---|---|---|
| `turn_start` | setActivity('thinking…'); showTurnIndicator() | Named event; `hx-on:turn_start` toggles a CSS class on `#activity` | Yes (1-line `hx-on`) |
| `turn_end` | endAssistantMessage(); hideTurnIndicator(); setStreaming(false); refreshStatusLineUsage() | Named event; `hx-on:turn_end` + an OOB swap that refreshes `#usage` | Yes |
| `message_start` | startAssistantMessage(role); setActivity('responding…') | OOB swap: `<div id="turn-{N}" hx-swap-oob="true"></div>` opens the live block; OOB `#activity` pill | Yes |
| `message_update` (text) | appendTextDelta() — re-render markdown into live block | **The hard one** — see §5.1 | Partial |
| `message_update` (thinking) | appendThinkingDelta() | OOB `hx-swap="beforeend"` into `#thinking-{N}` | Yes |
| `message_update` (toolcall_args) | appendToolArgsDelta() | OOB `hx-swap="beforeend"` into `#toolcall-args-{N}` | Yes |
| `message_end` | endAssistantMessage() | Named event or OOB swap that finalizes the live block | Yes |
| `tool_execution_start` | startToolCall() — builds a tool card (1240-1304) | OOB swap: server emits the full `<div class="tool-card" id="tool-{callId}">…</div>` | Yes |
| `tool_execution_end` | endToolCall() — finalizes card (1304-1400) | OOB swap: server emits the finalized `<div class="tool-card" id="tool-{callId}">…</div>` (full re-render) | Yes |
| `tool_execution_update` | appendSubagentEntry() + appendSubagentPanelEvent() (422 lines) | OOB `hx-swap="beforeend"` into `#subagent-log-{callId}` | Yes |
| `tool_permission_request` | renderPermissionModal() (1542-1610) | OOB swap: server emits the modal HTML into `#permission-modal` | Yes |
| `agent_error` | appendError(); setStreaming(false); hideTurnIndicator() | Named event; `hx-on:agent_error` + OOB error toast | Yes |
| `agent_interrupted` | endAssistantMessage(); hideTurnIndicator() | Named event; same as turn_end variant | Yes |
| `session_switched` | loadSessions() + reload transcript | Named event; `hx-trigger="session_switched from:body"` re-fetches `#session-list` and `#conversation` | Yes |
| `ping` | noteEvent() (watchdog) | Named event; `hx-on:ping` stamps watchdog | Yes (1-line) |

**Summary: 11 of 12 event types map cleanly to OOB swaps or named
events. Only `message_update` (text deltas) needs special handling.**

## 4. What the server change looks like

Today there is **one** function that converts every `AgentEvent` to an
SSE frame: `encodeEventJson` (`src/agent/wire.zig`, ~130 lines) +
`renderFrame` (`src/coding/sse.zig`, 5 lines). The migration adds a
sibling `encodeEventHtml` that emits HTML fragments instead of JSON.
The `renderFrame` wrapper changes from:

```zig
return std.fmt.allocPrint(a, "event: {s}\ndata: {s}\n\n", .{ kind, json });
```

to (for OOB-carrying events):

```zig
return std.fmt.allocPrint(a, "data: {s}\n\n", .{html_fragment});
```

(unnamed event → htmx processes OOB swaps), or keeps the `event:` name
for lifecycle signals (`turn_start`, `turn_end`, `agent_error`,
`session_switched`, `ping`).

**This is one conversion point**, not a scatter. The agent loop, the
session broadcast, the replay ring, the keepalive pings — all unchanged.
Only the final frame-content encoder changes.

## 5. The streaming-text problem (the one real difficulty)

`message_update` with `deltaKind:"text"` arrives per token. Today the
client appends the delta to a growing string, re-runs the markdown
renderer over the whole accumulated block, and sets `innerHTML`. This
gives correct incremental markdown (a `**bold**` that spans two deltas
renders correctly once both arrive).

htmx swaps are element-granular. Two approaches:

### 5.1 Option A — server renders markdown per delta (recommended for max reduction)

The server maintains the accumulated text for the current block and, on
each `message_update` text delta, emits a full re-rendered HTML fragment
for the block:

```
data: <div id="msg-{blockIndex}" hx-swap-oob="true">{rendered_markdown_so_far}</div>
```

htmx swaps the whole block each time. The client does nothing.

**Cost:** the server needs a markdown renderer. Today the markdown
renderer is in JS (~210 lines). It would move to Zig (~300-400 lines to
match the subset). SSE bandwidth rises: a full HTML block per token vs a
small `{"delta":"foo"}` blob. For a 500-token response, that's ~500 full
block re-renders over the wire — each larger than the last. Practical
for a local single-user proxy (the documented deployment), possibly
heavy for remote/orchestrator use.

**Benefit:** the client's streaming-render code (markdown renderer +
`appendTextDelta` + the live-block accumulation + Prism triggering) —
~300+ lines — is deleted entirely. The client becomes truly dumb for
text: htmx swaps the block, done.

### 5.2 Option B — keep client-side streaming render, htmx everything else

`message_update` text deltas stay as JSON (named event), and a small
JS handler appends + re-renders. Everything else uses htmx OOB. This
is the **partial** path: htmx for 11/12 event types, vanilla JS for the
text-delta path only.

**Cost:** the markdown renderer + `appendTextDelta` stay (~250 lines of
JS). A small `hx-on:message_update` handler calls the renderer.

**Benefit:** no server-side markdown renderer, no bandwidth increase.
Still eliminates ~1500+ lines of JS (all the other event handlers, tool
cards, sub-agent panel, status line, sidebar, design docs).

### 5.3 Recommendation

Start with **Option B** (partial — keep client-side text rendering,
htmx everything else). It's the lower-risk path, yields the bulk of the
reduction, and doesn't require a Zig markdown renderer. If the
streaming-text path is later wanted server-side too, Option A can be
layered on top (replace the one `hx-on:message_update` handler with an
OOB swap from the server).

## 6. What stays client-side (the irreducible JS)

Even with a full migration, these need JS (htmx doesn't replace them):

1. **Prism syntax highlighting** — runs after each markdown swap. A
   one-line `htmx:after:swap` hook calls `Prism.highlightAllUnder(target)`.
   ~5 lines. (If Option A, this is the only post-swap JS.)
2. **Slash-command palette** — keyboard UX: type `/`, fuzzy-filter,
   arrow-navigate, Enter. htmx can fetch the filtered list via
   `hx-get="/commands?q=..."` on `keyup` (debounced), but arrow-nav +
   selection highlight are JS. ~80 lines.
3. **Prompt history** — `↑`/`↓` cycling through a localStorage ring.
   ~70 lines. Pure client state; htmx doesn't help.
4. **Composer** — Enter-to-send, Shift-Enter newline. ~20 lines.
5. **Sidebar toggle / mobile drawer** — could be `<details>`, ~0 lines.

If Option B: add the markdown renderer (~210 lines) +
`appendTextDelta` (~30 lines).

**Irreducible JS total:** ~175 lines (Option A) or ~415 lines (Option B),
down from 3403. That's a **~95% reduction** (Option A) or **~88%
reduction** (Option B, since the markdown renderer stays but the 262
event-listener + 541 tool-card + 422 subagent + 195 status + 141
sidebar + 225 design-docs = ~1786 lines go away).

## 7. Revised recommendation

**Pursue the migration, in two phases.**

### Phase 1 — hx-sse for all non-text events (Option B, §5.2)

- Add `encodeEventHtml` to `wire.zig` for the 11 non-text event types.
- Change `renderFrame` to emit unnamed events (OOB) for content events
  and named events for lifecycle.
- Rewrite `index.html` with `hx-sse:connect="/events"` + OOB target
  elements (`#conversation`, `#tool-{callId}`, `#subagent-log-{callId}`,
  `#permission-modal`, `#status`, `#activity`, `#session-list`, etc.).
- Convert the request/response panels (sessions, role, usage,
  design-docs, transcript, command, permission) to htmx `hx-get`/`hx-post`.
- Keep the markdown renderer + `appendTextDelta` for `message_update`
  text deltas (one `hx-on:message_update` handler).
- Keep Prism, slash palette, prompt history.

**Estimated reduction:** ~1786 lines of JS eliminated (event listeners
+ tool cards + subagent panel + status line + sidebar + design docs)
for ~300-400 lines of Zig HTML fragment builders (in
`encodeEventHtml`). Net ~1400 lines removed. `app.js` 3403 -> ~1600.

### Phase 2 — server-side markdown rendering (Option A, §5.1, optional)

- Move the markdown renderer to Zig (~300-400 lines).
- `message_update` text deltas emit a full re-rendered HTML block as an
  OOB swap. Delete the client markdown renderer + `appendTextDelta`.
- `app.js` drops to ~175 lines (Prism hook + slash palette + prompt
  history + composer).

**Estimated further reduction:** ~415 lines of JS (markdown renderer +
delta handler) for ~400 lines of Zig. Net ~15 lines, but the client is
now truly thin and the "zero-dependency" markdown renderer becomes a
shared server asset.

## 8. Why I was wrong before

My first analysis said "the streaming core is a poor fit for htmx." That
was wrong because I treated each SSE event as needing a dedicated
client-side handler, when in fact `hx-swap-oob` lets the server drive
multi-element updates with zero client listeners. The 262-line
`addEventListener` block + the render functions it calls (~1500 lines)
exist *precisely* because the current architecture lacks a
server-driven swap mechanism — which is exactly what hx-sse provides.

The first analysis also overweighted "you'd need a Zig markdown
renderer" as a blocker. It's only needed for the text-delta path
(Option A), and Option B keeps the JS renderer while still
eliminating ~1786 lines. The markdown renderer is a Phase 2
optimization, not a prerequisite.

## 9. Risks and open questions

1. **SSE bandwidth (Option A only):** full HTML block per token
   increases wire size. Measure on a real turn. For local proxy use
   (the documented deployment) this is likely fine; for
   remote/orchestrator, Option B avoids it.
2. **OOB target IDs:** the server must emit stable, predictable element
   IDs (`#msg-{blockIndex}`, `#tool-{callId}`) that the page knows. The
   current JS generates these dynamically; the HTML shell must pre-create
   the containers or the OOB swap creates them. Verify hx-sse creates
   missing OOB targets or requires them to pre-exist.
3. **Tool-card full re-render:** `tool_execution_end` re-sends the
   entire tool card (name, args, result). For large tool outputs (e.g.
   a big `read` result) this re-sends stable content. Acceptable for a
   single-user proxy; could use `<hx-partial>` to target only the
   result region if needed.
4. **Sub-agent overlay:** the full-screen overlay is a second live
   region fed by `tool_execution_update`. With OOB, the server emits
   `<div id="subagent-log-{callId}" hx-swap-oob="true">…appended…</div>`
   and a separate `<div id="subagent-overlay-{callId}" hx-swap-oob="true">…</div>`.
   Two OOB targets per event — verify hx-sse handles multiple OOB
   elements in one frame (the docs show it does).
5. **Prism re-highlight:** `htmx:after:swap` fires per swap; call
   `Prism.highlightAllUnder(swap.target)`. Verify the event gives the
   swapped element. ~5 lines.
6. **htmx bundle size:** htmx core ~50 KB + hx-sse extension. The
   current UI ships zero framework JS. This reverses the "zero
   dependency" stance in `app.js` line 9 — but htmx is vendored
   (@embedFile), not a CDN dependency, consistent with the existing
   zero-build-pipeline decision.

## 10. Comparison to franky-box

| | franky-box admin | franky web UI (revised) |
|---|---|---|
| htmx fit | excellent (request/response CRUD) | good (hx-sse OOB for 11/12 events; text-delta path needs Option A or B) |
| JS eliminated | ~270 LoC (all of it) | ~1786 LoC (Phase 1) / ~3200 LoC (Phase 2) |
| Server grows by | ~150 lines (HTML builders) | ~300-400 lines (encodeEventHtml + optional markdown renderer) |
| Net reduction | ~111 lines | ~1400 (Phase 1) / ~1800 (Phase 2) |
| Risk | low | medium (streaming path; needs measurement) |
| Replay/reconnect | n/a | already implemented (Last-Event-ID ring) — survives unchanged |

The franky web UI migration is actually **bigger** than franky-box in
absolute line reduction, because `app.js` (3403 lines) is an order of
magnitude larger than franky-box's admin JS (270 lines), and the same
hx-sse mechanism replaces the bulk of it.

## 11. References

- htmx 4 `hx-sse` extension: https://four.htmx.org/extensions/hx-sse
- htmx 4 SSE OOB swaps + `<hx-partial>`: https://four.htmx.org/extensions/hx-sse (section "Update Elements")
- htmx 4 named events + `hx-on`: https://four.htmx.org/extensions/hx-sse (section "Trigger Client Events")
- Current event encoder: `src/agent/wire.zig` `encodeEventJson` (~130 LoC)
- Current frame renderer: `src/coding/sse.zig` `renderFrame` (5 LoC)
- Current SSE server: `src/coding/modes/proxy.zig` (5782 LoC, replay ring at ~2069)
- Current web UI: `src/coding/modes/web/app.js` (3403 LoC, 118 fns)
- franky-box htmx migration (for comparison): `franky-box` repo, branch `rfc/htmx-admin-ui`