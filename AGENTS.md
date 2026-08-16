Franky Codebase Analysis — Complete Report

**Generated:** 2026-07-03 — analysis of the full source tree at spec v2.3.0 (library v0.29.0).

## Overview

Franky is a provider-agnostic, streaming LLM agent framework written in Zig 0.17-dev. It's a mature, layered runtime (~1016 passing tests) for building tool-using AI agents, shipping with a complete coding-agent CLI out of the box.

Version: 0.29.0 (library root), built on Zig 0.17-dev (master), two vendored dependencies (zompress, agent_memory/SQLite 3.53.4).

## Codebase at a glance

| Metric | Value |
|---|---|
| Lines of code | ~50k+ across 100+ files |
| Tests | ~1016 (unit + integration) |
| Providers | 7 (Anthropic, OpenAI Chat, OpenAI Responses, OpenAI Gateway, Google Gemini, Google Vertex, + Faux for testing) |
| Built-in tools | 14 (read/write/edit/bash/ls/find/grep/subagent/web_search/web_fetch/workspace/memory_save/memory_search/ccr_retrieve) |
| Run modes | 3 (print/rpc/proxy) |
| Capability roles | 4 (read/plan/code/full) |
| Guardrails | 3 (stuck detector, compilation guard, finish_task) |

---
1. Architecture — Three-Layer Design

┌──────────────────────────────────────────────────┐
│  coding/  — tools, session, CLI modes            │
├──────────────────────────────────────────────────┤
│  agent/   — stateful, tool-using runtime         │
├──────────────────────────────────────────────────┤
│  ai/      — provider-agnostic LLM streaming      │
└──────────────────────────────────────────────────┘

Each layer depends only on the one below it. The sdk.zig facade re-exports a stable public surface for embedding.

---
2. ai/ Layer — LLM Streaming Engine

Key files: types.zig, errors.zig, stream.zig, channel.zig, registry.zig, http.zig, sse.zig, partial_json.zig, retry.zig, log.zig, transform.zig
Architecture

    Provider-agnostic: A Registry maps API tags (e.g. "anthropic-messages", "openai-responses", "faux") to streamFn function pointers. Seven providers ship.
    Event-driven streaming: Every LLM interaction produces a StreamEvent sequence on a bounded Channel — text deltas, thinking deltas, tool call deltas, errors.
    Reducer accumulates stream events into a final ai.types.Message (assistant's response).
    Cancel is a simple atomic boolean flag passed through the call chain for cooperative cancellation.

Key Types
Type	Purpose
Message	Tagged by role (user, assistant, tool_result, custom). Owns its content blocks.
ContentBlock	Union: text, thinking, image, tool_call
Context	Bundle of system_prompt + messages + tools sent to LLM
Model	{id, provider, api, context_window, max_output, cost, capabilities}
ThinkingLevel	off/minimal/low/medium/high/xhigh with provider-specific budget mappings
StreamEvent	Union of text/thinking/tool_call deltas, errors, metadata
Channel(T)	Generic bounded ring buffer with blocking push/pop and sticky-close semantics
ErrorDetails	Rich error context with Code enum (20 codes), sub-codes, HTTP status, retry timing
Diagnostics	v1.29.0 — per-message diagnostics (trace_id, finish_reason_raw, event counters)
Provider Interface

Every provider exports a streamFn with signature fn(StreamCtx) anyerror!void. It receives the model, context, options, and an output channel, and is responsible for translating the provider's wire format into the franky StreamEvent stream.
Error Handling

    Two-tier: Zig AgentError error set (compact, 20 tags) + ErrorDetails struct (rich context with sub-codes).
    fromToolResult helper maps tool failures into the error taxonomy.
    Retryability is explicit per Code — rate_limited, transient, timeout, transport are retryable.
    Errors flow through the stream as events, not exceptions — consumer decides what to surface.

Infrastructure

    Channel(T): Generic bounded ring with blocking blocking push/pop, closeWithFinal (bypasses capacity), tryPush/tryNext for non-blocking consumers. Uses std.Io.Mutex + std.Io.Condition for thread safety.
    http.zig: SSE streaming HTTP transport with per-phase timeouts (connect, upload, first-byte, event-gap). Retry logic in retry.zig.
    partial_json.zig: Incremental JSON parser for streaming tool-call arguments.
    log.zig: Leveled stderr logger (err/warn/info/debug/trace).

Thread Safety

    Channel operations are mutex-guarded and use std.Io condition variables.
    Providers are expected to push events from their own threads/context, bounded by channel capacity.

---
3. agent/ Layer — Stateful Tool-Using Runtime

Key files: agent.zig, loop.zig, types.zig, proxy.zig
Architecture

    Agent (facade): Owns state (model, tools, transcript, streaming flag), subscribers, worker thread. Methods: prompt, continueRun, steer, followUp, abort, interrupt, reset, waitForIdle.
    agentLoop (engine): The turn state machine — LLM call → tool dispatch → repeat.
    Transcript: Owned ArrayList(AgentMessage) — the conversation history.

Agent Loop Lifecycle

    turn_start emitted
    Context prepared (convert_to_llm hook for compaction/filtering)
    LLM call via registry.stream() → events consumed via runTurn
    Streaming events forwarded as message_update (text/thinking/toolcall_args)
    On stream end, Reducer.finalize() produces the assistant Message
    Tool calls detected; before_tool_call hooks run (can veto)
    Tools executed — all parallel (concurrent threads) or all sequential (sync loop), then results collected in source order
    Tool results appended to transcript; loop repeats if tools didn't request termination
    between_turns hook drains steer/followUp queues
    turn_end emitted; loop may stop on cancel/max_turns/terminate

Cancellation — Three Levels

    abort(): Hard stop — fires Cancel flag mid-turn, joins worker, emits agent_interrupted
    interrupt(): Graceful stop — current turn completes fully, then next turn is blocked
    stop_requested: Atomic flag checked between turns

Event Model (AgentEvent)

    Lifecycle: turn_start, turn_end, agent_interrupted, agent_error
    Streaming: message_start, message_update (text/thinking/toolcall_args), message_end
    Tool: tool_execution_start, tool_execution_update, tool_execution_end
    Permission: tool_permission_request (v1.11.1)

Tool Execution Model

    Hybrid: If ALL tools in a turn are .parallel, they run via std.Thread.spawn with done_flag atomics. If ANY tool is .sequential, all run synchronously in a for loop.
    Results are always collected in source order regardless of completion order.
    Hooks: before_tool_call (veto), role_denied (policy), after_tool_call (cleanup).

Observer Pattern

    subscribe(handler, userdata) → returns a subscription ID.
    Events are broadcast to all subscribers under a mutex.
    Decouples the core loop from UI/monitoring/CLI modes.

Notable Design Patterns

    Event Source: All state changes flow through AgentEvent stream.
    Facade: Agent wraps the raw loop complexity.
    Hook-based extensibility: tool_gate, max_turns_hook, convert_to_llm, between_turns — all pluggable via function pointer + userdata.
    Deterministic tool ordering: Results stored in source order regardless of parallel execution.

---
4. coding/ Layer — Tools, Session, Modes

Key files: ~40 files in src/coding/ organized into tools/, modes/, and infrastructure.
Tools (11 tools)
Tool	Key Design Decisions
read	Binary detection (NUL sniff on first 8KB), file size cap (256KB without explicit limit), per-line cap (50KB), continuation hints, path-safety via canonicalize
write	Atomic write (tempfile + rename), explicit overwrite flag, auto-creates parent dirs
edit	Atomic multi-edit (find/replace), all edits succeed or none do, diff output, backslash-escaping detection
bash	Shell execution via /bin/sh -c, cwd-locked, env-denylist, timeout support
ls	Recursive/respectGitignore, tree-style output
find	Glob matching (*, **, ?, [abc]), .git auto-exclusion
grep	Literal substring search, regex option, gitignore-aware
subagent	Delegates to a sub-agent with its own model/profile
web_search	Web search via configured API
web_fetch	Full page content fetch
truncate, workspace	Utility tools
Architecture Pattern: Context-Aware Tooling

Tools provide multiple construction functions:

    tool() — standalone (tests, simple usage)
    toolWithWorkspace(ws) — workspace-scoped (path safety enforced)
    toolWithCtx(ctx) — with additional runtime context overlays

Modes (3 modes)
Mode	Purpose
print	One-shot prompt → streamed output → exit. Default.
rpc	JSON-RPC over stdio for programmatic clients
proxy	HTTP/SSE listener on 127.0.0.1:8787/ with built-in web UI
Infrastructure Highlights

    session.zig: ULID-based session IDs, atomic writes (tempfile + rename), object store for blobs ≥32 KiB, branching (fork/checkout)
    role.zig: Capability tiers — read (inspect only), plan (workspace writes, no shell), code (adds bash), full (all tools, no restrictions)
    permissions.zig: Tool-level permission overlay with --allow-tools, --deny-tools, --ask-tools, --remember-permissions. Bash fingerprinted by first non-path token
    path_safety.zig: Workspace path canonicalization, escape detection, path safety for ../ traversal
    gitignore.zig: Multi-level .gitignore parsing with negation patterns
    env_denylist.zig: Blocks dangerous env vars from bash subprocesses
    cli.zig: Comprehensive CLI argument parsing with env var fallbacks
    extensions.zig: Tier-1 static module extension loading; Tier-2/3 (.so/.dylib/Wasm) deferred
    settings.zig, auth.zig, models.zig: JSON-based configuration with $FRANKY_HOME directory layout

Session Persistence

~/.franky/
  sessions/<ulid>/
    session.json       # header: id, timestamps, model, provider
    transcript.json    # full conversation history
    tree.json          # branch graph
    object_store/      # content-addressed blobs ≥32 KiB
  permissions.json     # persisted allow/deny decisions
  models.json          # §H.3 model catalog (hand-curated + live-polled)
  settings.json        # runtime limits
  auth.json            # bearer token records
  diagnostics/         # cross-session self-improvement data
  logs/                # auto-diverted logs

---
5. SDK Facade (src/sdk.zig)

Programmatic entry point for embedding franky in other Zig programs. Re-exports the stable public surface (ai, agent, coding modules) with versioned API stability guarantees.

---
7. Test Suite

~1016 tests across:

    Unit tests: Inline in every source file (types, channels, errors, tools, gitignore, etc.)
    Integration tests (test/):
    agent_loop_test.zig — End-to-end: agent + faux provider + tool round-trip
    agent_class_test.zig — Stateful Agent: subscribe/prompt/reset
    gitignore_test.zig — Multi-level .gitignore with real filesystem tree
    parallel_tools_test.zig — Parallel tool execution correctness
    kitchen_sink_test.zig — Combined feature interaction
    replay_test.zig — Session replay from stored transcripts
    Spec anchor checker (src/bin/check_spec_anchors.zig): Verifies every §-reference in source resolves to a spec heading at build time.

Testing Patterns

    std.testing.allocator for leak detection
    franky.test_helpers.threadedIo() for concurrent test contexts
    Faux provider (scripted fake LLM) for deterministic tests
    State-machine-style assertions over filesystem round-trips

---
8. Build System & Configuration
Build (build.zig)

    Single franky module exposed via b.addModule("franky", …)
    Binaries: franky (main CLI), franky-gen-models (model catalog poller), franky-check-spec-anchors
    6 integration test binaries
    LLVM/LLD opt-in for macOS compatibility

Dependencies: Two vendored — zompress (v0.1.1) and agent_memory (SQLite 3.53.4 via franky-memory v0.0.2)
CI/CD

    GitHub Actions workflows
    GoReleaser for release artifacts (.goreleaser.yaml)
    ContainifyCI for containerized testing (.containifyci/containifyci.go)
    Docker sandbox (Dockerfile.sandbox) with Zig 0.17-dev

Documentation

    docs/spec/v1.md, docs/spec/v2.md — Versioned specification documents
    docs/design/ — Design decisions and rationale
    docs/archive/ — Historical docs
    docs/todos/ — TODO tracking
    Spec anchor discipline: every source §-reference cross-checks against spec headings at build time

Skills

    skills/zig-merged-kb.md — Zig 0.16+/0.17-dev programming reference loaded as a skill bundle

---
9. Key Design Principles

    Streams, not callbacks — Every LLM interaction and agent turn is a sequence of events on a Channel. Completion is layered on top of streams, not hidden underneath them.
    Errors as events, not exceptions — Provider failures flow through the stream as error_ev events carrying structured ErrorDetails.
    Plain-JSON persistence — Contexts, transcripts, and sessions are structurally serializable. Writes are atomic (tempfile + rename).
    Hooks return decisions, not mutations — beforeToolCall returns {block, reason} — it does not mutate the caller's state.
    Deterministic transcripts — Tool results are stored in source order regardless of completion order.
    Layered modules — ai stands alone; agent adds state machines; coding adds tool/prompt set.

---
## Key Findings from Deep Analysis

The following findings were surfaced by an automated deep-code audit of every module in the source tree. They are organized by severity.

---

### 🔴 Critical Issues

1. **Proxy subscriber slot leak (confirmed, todos.md)**
   - **Location:** `src/agent/proxy.zig` — `fanOutLocked` and `runSseStream`
   - **Symptom:** After ~32 browser reconnects (browser background tab, OS-level half-close, network blip), all subscriber slots are exhausted. The process must be restarted.
   - **Root cause:** When a client disconnects without sending FIN/RST, `fanOutLocked` sets `sub.closed = true` but does **not** shut down the read side of the socket. The reader thread stays blocked on `readVec`, the `defer removeSub` never runs, and the subscriber slot leaks forever. Each reconnect adds a fresh subscriber until `max_subs = 32` is reached.
   - **Fix needed:** `fanOutLocked` must shut down the read side of the socket (e.g. via `std.posix.shutdown`) when it sets `sub.closed = true`, forcing `readVec` to return immediately and `removeSub` to fire.

2. **Object store `sweep` can cause silent data loss**
   - **Location:** `src/coding/object_store.zig` lines 102–115
   - **Symptom:** Content-addressed blobs referenced by the transcript are deleted, producing `error.ObjectNotFound` on subsequent reads.
   - **Root cause:** `sweep()` relies on an externally-supplied `keep` list of SHA-256 hashes. If the caller passes an incomplete `keep` list (missing a hash that a `Ref` in `transcript.json` references), the blob is deleted.
   - **Mitigation:** The `transcript.json` ref-extraction logic must guarantee completeness. Add an assertion that verifies every `Ref` in the transcript resolves to a kept hash before calling `sweep`.

3. **Grep regex `\b` and word-boundary assertions reject valid model output**
   - **Location:** `src/coding/tools/grep.zig` — regex engine does not support `\b` (ECMAScript subset)
   - **Symptom:** Models that emit `\b` word-boundary assertions receive `grep_bad_regex` with no actionable fix.
   - **Impact:** Ongoing issue reported in todos.md. Affects any model that uses regex word boundaries in pattern construction.
   - **Fix needed:** Either pre-process patterns to strip/convert `\b`, switch to a richer regex engine (PCRE2 via libc, or a Zig-native regex), or auto-detect and suggest `use regex=false` with better UX.

---

### 🟡 High-Severity Issues

4. **`catch return` voids `errdefer` chains**
   - **Location:** Multiple files in `agent/loop.zig` and `agent/agent.zig`
   - **Pattern:** `const x = tryOrReturn(fn()) catch return;` followed by `errdefer cleanup(x);` — the `errdefer` never fires because `catch return` already returned from the function in a non-error-union context. The `errdefer` is dead code.
   - **Fix needed:** Convert `catch return` to a `!void` wrapper so `errdefer` is triggered on the error path, or move cleanup into a helper that runs before the `return`.

5. **`freeSessionHeader` is fragile — field additions cause silent leaks**
   - **Location:** `src/coding/session.zig` lines 147–151
   - **Symptom:** Adding a new owning-string field to `SessionHeader` will silently leak unless `freeSessionHeader` is also updated.
   - **Fix needed:** Use compile-time reflection to deinit all string fields automatically, or add a `comptime` assertion that verifies every field is freed.

6. **No end-to-end tests for the three run modes**
   - **Location:** `src/coding/modes/` — `print.zig`, `rpc.zig`, `proxy.zig`
   - **Gap:** CLI parsing is tested, but the mode drivers (print/rpc/proxy) have zero integration tests. The RPC framer is tested in `kitchen_sink_test.zig` but not the full request/response lifecycle.
   - **Risk:** Mode-specific bugs (e.g. the proxy subscriber leak) escape detection until they manifest in production.

---

### 🟡 Medium-Severity Issues

7. **`nowMillis()` returns 0 on error, degrading timing-dependent guards**
   - **Location:** `src/ai/stream.zig` lines 36–53
   - **Impact:** All timing-dependent code (stuck detector, SSE handler-stall timeout, usage timing) treats 0 as "clock unavailable". But 0 could mask real timing issues. The guardrails/stuck detector compares elapsed time against 0 — if `nowMillis` returns 0, stuck detection may silently degrade.
   - **Note:** Only affects non-Linux POSIX platforms where `libc.clock_gettime` fails, which is rare.

8. **Compaction `replaceSpanWithSummary` uses manual `memcpy` — brittle**
   - **Location:** `src/coding/compaction.zig` lines 556–566
   - **Risk:** Array splicing with `std.mem.copyForwards` is correct but fragile. A single off-by-one on source/destination regions corrupts the transcript silently.
   - **Mitigation:** Add exhaustive unit tests covering edge cases (start=0, end=len, empty insertion, single-element removal).

9. **Partial JSON parser has no dedicated test coverage**
   - **Location:** `src/ai/partial_json.zig`
   - **Risk:** The incremental JSON state machine is complex and critical for correct tool-call argument streaming, but has no focused test suite.

---

### 🟢 Low-Severity / Cosmetic

10. **`SubAgent final_text` occasionally empty**
    - **Location:** `src/coding/tools/subagent.zig` — reported in todos.md
    - **Symptom:** Sub-agent calls complete without `final_text` despite having tool calls and a full transcript.
    - **Likely cause:** Race condition or edge case in sub-agent turn reporting.

11. **DeepSeek tool-call JSON parsing issues**
    - **Location:** todos.md — reported as recurring
    - **Symptom:** DeepSeek models emit tool calls in non-standard JSON format that the parser rejects.

12. **`end_turn` not emitted by smaller models**
    - **Symptom:** Some models (especially smaller ones) never emit `end_turn`, causing infinite tool-call loops.
    - **Mitigations exist:** Checkpoint injection, hard budget with forced summarization, repetition-triggered escalation. But the problem persists.

---

### ✅ Notable Strengths (reinforced by deep audit)

- **Two vendored dependencies** — zompress (compression) and agent_memory (SQLite 3.53.4); otherwise pure Zig.
- **Mature threading model** with three-level cancellation (abort/interrupt/stop_requested).
- **Comprehensive error taxonomy** with retryability metadata and structured ErrorDetails.
- **Atomic file operations** throughout session persistence and tool execution (tempfile + rename).
- **Permission system** with role tiers (4 levels), tool-level gates, bash verb fingerprinting, and persistent allow/deny.
- **Spec-driven development** with automated cross-reference checking (spec anchors + doc links).
- **7 LLM providers** with unified streaming interface.
- **~1016 tests with leak detection** on every run via `std.testing.allocator`.
- **Thorough memory management** — every allocation paired with `defer`/`errdefer`, arena allocators for session-scoped data.
- **Guardrails** for unattended operation: stuck detection, compilation checking, finish_task enforcement.

---

## Recommended Next Steps

1. **Fix the proxy subscriber leak** — highest priority; affects all proxy-mode users.
2. **Fix grep regex `\b` handling** — affects all models that use word boundaries.
3. **Audit all `catch return` patterns** for voided `errdefer` chains across `agent/`.
4. **Add mode-level integration tests** — smoke tests for print/rpc/proxy modes.
5. **Harden `freeSessionHeader`** with compile-time field iteration.
6. **Add `sweep` completeness assertion** — verify every `Ref` is in the `keep` list before deletion.
7. **Cover `partial_json.zig`** with a dedicated unit-test suite.
8. **Investigate the sub-agent empty-final-text edge case**.
9. **Consider switching the regex engine** to one that supports `\b` (PCRE2 via libc, or a Zig-native regex library).
