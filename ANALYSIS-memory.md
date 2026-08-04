# TencentDB Agent Memory — Deep Analysis & Zig Integration Plan for Franky
_(Embedded-Only Edition — persistence via SQLite, intelligence via franky's LLM registry)_

## Table of Contents
1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview of TencentDB Agent Memory](#2-architecture-overview)
3. [Deep Analysis: The "Database Memory" (MemoryCore)](#3-deep-analysis-memorycore)
4. [The L1 Extraction Pipeline — What It Is and Why](#4-the-l1-extraction-pipeline--what-it-is-and-why)
5. [Franky Integration Points](#5-franky-integration-points)
6. [Proposed Zig Implementation — `agent-memory-zig` (Embedded Only)](#6-proposed-zig-implementation--agent-memory-zig-embedded-only)
7. [Phased Roadmap](#7-phased-roadmap)
8. [API & Schema Reference](#8-api--schema-reference)

---

## 1. Executive Summary

TencentDB Agent Memory (TAM) is a **layered, persistent memory system for LLM agents**. It distills raw conversations (L0) into atomic facts (L1), scenario context blocks (L2), and long-term persona profiles (L3), then retrieves them via hybrid BM25 + vector search with RRF fusion to bootstrap the next session.

The "Database Memory" part lives in **`MemoryCore/`** — a standalone Node.js/TypeScript service that:
- Stores L0–L3 in **SQLite + sqlite-vec + FTS5** (local) or Tencent Cloud VectorDB (remote).
- Runs an **async pipeline** (LLM-driven extraction, dedup, scene segmentation, profile sync) to refine raw turns into structured memory.
- Exposes an HTTP Gateway with v2/v3 REST APIs.

**Recommendation:** Build a **standalone Zig package `agent-memory-zig`** (mirroring the `zompress` pattern) that implements an **embedded-only** memory store backed by SQLite. No external Node.js process, no remote HTTP gateway — everything runs inside the franky binary. The package:

1. **Phase 1:** Implements the **storage + retrieval layer** — SQLite tables for L0/L1, FTS5 for BM25 keyword search, cosine similarity for vector search, RRF fusion, L2/L3 as markdown files. Pure data plane, no LLM calls.
2. **Phase 2:** Implements the **L1 extraction pipeline** — porting the extraction + dedup prompts and calling **franky's own LLM registry** (`ai.registry.Registry`) to distill L0 conversations into L1 memories. This is the "thinking" part of memory.
3. **Phase 3:** Implements the **L2/L3 profile synthesis** — LLM-driven aggregation of L1 memories into scenario blocks and persona profiles.

The key architectural decision: **persistence is SQLite, intelligence is franky's LLM**. The Zig package owns the database; franky owns the brain.

---

## 2. Architecture Overview of TencentDB Agent Memory

The monorepo has four main components:

```
TencentDB-Agent-Memory/
├── MemoryCore/          ← THE "Database Memory" (this analysis)
│   ├── src/core/        L0–L3 memory, store, storage, skill, profile
│   ├── src/gateway/     HTTP Gateway (v2 + v3 routers)
│   ├── src/offload*/    Context compaction pipeline (L1.5/L2 MMD)
│   ├── src/metadata/    User/Team/Agent/Task/Asset management plane
│   ├── src/services/    Pipeline scanner, workers, scheduling
│   └── sdk/             (in repo root /sdk/) Python + TypeScript SDKs
├── MemoryProxy/         Sidecar proxy for Claude Code / CodeBuddy
├── MemoryKnowledge/     Wiki + CodeGraph ingestion & retrieval
├── MemoryPanel/         Web UI for team memory management
└── deploy/              Docker orchestration for all services
```

**Memory pyramid (L0→L3):**

| Layer | What it stores | Storage form | Primary use | How it's created |
|-------|---------------|--------------|-------------|------------------|
| **L0 Conversation** | Raw messages (role, text, timestamp) | SQLite rows + optional vector | Verify exact wording/sources | Direct capture (no LLM) |
| **L1 Atom** | Facts, preferences, constraints, events | SQLite rows + vector + FTS index | Precise recall | **LLM extraction** from L0 + dedup |
| **L2 Scenario** | Knowledge blocks per project/scenario | Markdown files (`scene_blocks/*.md`) | Restore working context | LLM scene segmentation + aggregation |
| **L3 Core/Persona** | Long-term profiles, stable patterns | Markdown file (`persona.md`) | Rapid context bootstrap | LLM profile synthesis from L1/L2 |

**Data flow (embedded mode, what we're building):**

```
Franky Agent Loop
  │
  │ 1. Turn completes → capture messages to L0 (SQLite, no LLM)
  │ 2. Periodically (every N turns or on session end):
  │    └→ L1 Extraction Pipeline:
  │         a. Read recent L0 messages
  │         b. Build extraction prompt
  │         c. Call franky's LLM registry (the SAME model the user chose)
  │         d. Parse JSON response → scene-segmented memories
  │         e. Dedup: search existing L1 for similar records (vector/FTS)
  │         f. Call LLM again for conflict detection (store/update/merge/skip)
  │         g. Write new/updated L1 records to SQLite + FTS + vector
  │ 3. Before next prompt → Recall:
  │    └→ Hybrid search L1 (vector + BM25 + RRF)
  │    └→ Read L2/L3 markdown
  │    └→ Inject as bounded [Memory Context] block in system prompt
  ▼
SQLite database (~/.franky/memory.db)
  + scene_blocks/*.md
  + persona.md
```

---

## 3. Deep Analysis: MemoryCore (The "Database Memory")

### 3.1 Storage Layer (`src/core/store/`)

The store is **backend-agnostic** via the `IMemoryStore` interface. The SQLite implementation (`sqlite.ts`, ~3400 lines) is what we port:

- Uses Node 22+ built-in `node:sqlite` (sync `DatabaseSync` API).
- **sqlite-vec** extension for vector similarity (cosine, vec0 virtual tables).
- **FTS5** for full-text keyword search (BM25-ranked).
- **WAL mode**, busy_timeout=5s, 64MB page cache, 128MB mmap.
- Two parallel tables per layer:
  - `l1_records` (relational metadata) + `l1_vec` (vec0 virtual table)
  - `l0_conversations` + `l0_vec`
- Upsert = delete + insert (vec0 doesn't support ON CONFLICT).
- **Deferred embedding**: writes metadata-only, computes embedding in background.
- **Degraded mode**: if sqlite-vec fails to load, all ops become safe no-ops (FTS-only).

**File-based storage** (`src/core/storage/types.ts`) for L2/L3:
```
scene_blocks/{name}.md     — L2 scene blocks (markdown)
persona.md                — L3 user persona (markdown)
conversations/{date}.jsonl — L0 append-only log (backup)
records/{date}.jsonl       — L1 append-only log (backup)
.metadata/scene_index.json — scene index
.metadata/checkpoint.json  — pipeline cursor
```

SQLite is the primary retrieval engine; JSONL files are append-only backups.

### 3.2 Key Types (from `store/types.ts`)

```typescript
// L1 structured memory record (the "atoms" of memory)
interface L1RecordRow {
  record_id: string;    // "msg-xxx" or "mem-xxx"
  content: string;      // the memory text, e.g. "User prefers dark mode"
  type: string;         // "persona" | "episodic" | "instruction"
  priority: number;     // 0-100, higher = more important
  scene_name: string;   // scenario label, e.g. "debugging auth module"
  session_key, session_id, team_id, task_id, user_id, agent_id: string;
  version: number;      // optimistic locking
  timestamp_str, timestamp_start, timestamp_end, created_time, updated_time: string;
  metadata_json: string; // {scope, method_type, ...}
}

// L0 raw conversation
interface L0Record {
  id, sessionKey, sessionId, teamId, userId, agentId, taskId: string;
  role: string;         // "user" | "assistant" | "tool"
  messageText: string;
  recordedAt: string;
  timestamp: number;    // epoch ms
}
```

**Three memory types** (from `l1-writer.ts`):
- `persona` — user preferences, traits, stable facts about the user ("User's name is Alice", "User prefers concise answers")
- `episodic` — events, decisions, what happened ("Decided to use PostgreSQL instead of MySQL", "Fixed the auth bug in login.go")
- `instruction` — constraints, rules, how-to ("Never commit directly to main", "Always run tests before pushing")

### 3.3 Retrieval — Hybrid Search + RRF

Search combines three signals (`search-utils.ts`):

1. **Vector similarity** — cosine distance via sqlite-vec (or brute-force for small datasets).
2. **FTS5 BM25** — keyword search with jieba Chinese segmentation fallback to Unicode splitting.
3. **RRF (Reciprocal Rank Fusion)** — merges ranked lists: `score = Σ 1/(k + rank + 1)`, k=60.

```typescript
// RRF merge (search-utils.ts) — the actual fusion algorithm
for (const list of lists) {
  for (let rank = 0; rank < list.length; rank++) {
    const score = 1 / (k + rank + 1);  // k=60
    // accumulate per record_id
  }
}
// sort by summed RRF score
```

Results are **capped** by item count, character budget, and timeout to prevent memory from overwhelming the context window.

**Capability flags** (`StoreCapabilities`):
- `vectorSearch`, `ftsSearch`, `nativeHybridSearch`, `sparseVectors`
- Callers degrade gracefully: if no embeddings, fall back to BM25-only.

### 3.4 Embedding Service (`store/embedding.ts`)

Two providers:
- **"openai"** — OpenAI-compatible embedding API (configurable base URL, e.g. `text-embedding-3-small`).
- **"local"** — `node-llama-cpp` with `embeddinggemma-300m` (Q8_0, ~300MB, 768-dim).
- **"none"** — disabled; BM25-only retrieval (default for standalone, zero external deps).

Provider/model changes trigger **reindex** (detected via persisted `EmbeddingProviderInfo`).

For the Zig embedded version, we start with `"none"` (BM25-only) and add `"openai"` (HTTP call to an embedding API) as a configuration option. The local llama.cpp path is out of scope — too heavy for a Zig library dependency.

### 3.5 Profile Sync (L2/L3) (`core/profile/profile-sync.ts`)

L2/L3 are stored as **markdown files** (not SQL rows):
- `scene_blocks/*.md` — L2 scenario blocks, one file per scene
- `persona.md` — L3 persona (single file per team+agent)
- **Optimistic locking** via `version` + `contentMd5`
- Stable ID: `profile:v1:${sha256(scope + "\0" + type + "\0" + filename)}`
- The L3 persona file in "code mode" stores the "Team Operating Doctrine" — a set of stable working rules.

### 3.6 Isolation & Multi-Tenancy (`core/store/isolation.ts`)

Every write carries **`(team_id, user_id, agent_id, session_id, task_id?)`**. Every query accepts an `IsolationFilter` to narrow dimensions. For franky's embedded single-user mode, these default to `"default"` but remain in the schema so multi-agent support can be added later.

---

## 4. The L1 Extraction Pipeline — What It Is and Why

This is the **heart of the memory system**. Without it, you just have a chat log (L0). With it, you have *understanding* (L1). This section explains it in depth because it's the most conceptually important part to get right in the Zig port.

### 4.1 The Problem It Solves

Imagine you have 50 conversations with an agent over a month. The raw L0 log might be 100,000 messages. When you start a new session, you cannot stuff all 100k messages into the context window. Even if you could, most of them are noise:

```
User: hey
Assistant: hi! how can I help?
User: what's 2+2
Assistant: 4
User: cool
Assistant: 👍
User: can you help me set up a postgres database?
Assistant: sure! let me walk you through it...
```

The first 6 messages are worthless. The last 2 contain a decision ("set up postgres"). The L1 extraction pipeline reads L0 and produces compact, self-contained memory atoms:

```json
[
  {
    "scene_name": "setting up postgres database",
    "memories": [
      {
        "content": "User decided to use PostgreSQL for their database",
        "type": "episodic",
        "priority": 75,
        "source_message_ids": ["msg-007", "msg-008"]
      }
    ]
  }
]
```

Now, next session, instead of replaying 100k messages, you recall this L1 record (a few hundred bytes) and the agent immediately knows: "this user uses PostgreSQL." That's the value proposition.

### 4.2 The Pipeline (Step by Step)

Source: `core/record/l1-extractor.ts` + `core/prompts/l1-extraction.ts`

```
L0 messages (raw)
     │
     ▼
┌─────────────────────────────────┐
│ Step 1: Read & Split            │
│ Read recent L0 messages.        │
│ Split into:                     │
│   - background (context, ~10)    │
│   - new (to extract, ~20)       │
│ Track previous_scene_name.      │
└─────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────┐
│ Step 2: Build Extraction Prompt │
│ System prompt = instructions    │
│   for scene segmentation +      │
│   memory extraction.            │
│ User prompt = background msgs + │
│   new msgs + previous scene.    │
└─────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────┐
│ Step 3: Call LLM                 │  ← This is where franky's
│ Send the prompt to the LLM.     │    ai.registry.Registry
│ Get back a JSON string.         │    comes in.
└─────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────┐
│ Step 4: Parse JSON Response      │
│ Extract:                        │
│   [{ scene_name, memories: [{   │
│     content, type, priority,    │
│     source_message_ids,         │
│     metadata                    │
│   }] }]                         │
└─────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────┐
│ Step 5: Batch Dedup              │
│ For each extracted memory:      │
│   a. Search existing L1 for     │
│      similar records (vector/   │
│      FTS top-K).                │
│   b. If candidates found:       │
│      Call LLM again with all     │
│      new + candidate pairs.     │
│      LLM decides per memory:    │
│        store (new, no conflict) │
│        update (replace old)     │
│        merge (combine)          │
│        skip (duplicate)         │
└─────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────┐
│ Step 6: Write to Store            │
│ For each decision:              │
│   store  → INSERT new L1 record │
│   update → DELETE old + INSERT  │
│   merge  → DELETE old + INSERT  │
│            with merged content  │
│   skip   → do nothing           │
│ Also append to JSONL backup.    │
└─────────────────────────────────┘
```

### 4.3 The Extraction Prompt (What the LLM Sees)

**System prompt** (`EXTRACT_MEMORIES_SYSTEM_PROMPT`, ~4000 chars) tells the LLM:

```
You are a "scene segmentation and memory extraction expert."
Your task: analyze the user's conversation, detect scene changes,
and extract structured core memories (persona, episodic, instruction only).

### Task 1: Scene Segmentation
Analyze [new messages] + [previous scene], determine current scene.
- Inherit: no clear switch → keep previous scene.
- Switch: user issues explicit new directive, intent shifts, or new goal.
- One conversation may have one or multiple scenes.

### Task 2: Memory Extraction
Extract only from [new messages], using background for context.

[Universal principles]
1. Quality over quantity: filter chitchat, one-time ops, unreliable info.
2. Self-contained: memory must make sense without conversation context.
3. User/AI-centric: the subject must be "User (name)" or "AI".

Memory types:
1. persona — user preferences, traits, stable facts
2. episodic — events, decisions, what happened
3. instruction — constraints, rules, methods

Output: JSON array [{ scene_name, memories: [{ content, type, priority, source_message_ids, metadata }] }]
```

**User prompt** (built by `formatExtractionPrompt`):
```
[Previous scene]: debugging auth module

[Background messages] (context only, do NOT extract from these):
[msg-001] [user] [2025-01-15T10:00:00Z]: hey
[msg-002] [assistant] [2025-01-15T10:00:01Z]: hi! how can I help?
[msg-003] [user] [2025-01-15T10:05:00Z]: the login page keeps crashing

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[New messages] (extract memories from THESE):
[msg-004] [user] [2025-01-15T10:05:30Z]: I found the bug, it was a nil pointer in the auth middleware
[msg-005] [assistant] [2025-01-15T10:05:45Z]: great! want me to fix it?
[msg-006] [user] [2025-01-15T10:06:00Z]: yes, and add a test for it
[msg-007] [assistant] [2025-01-15T10:08:00Z]: done, test passes
```

**LLM response** (JSON):
```json
[
  {
    "scene_name": "debugging auth module",
    "memories": [
      {
        "content": "User found a nil pointer bug in the auth middleware causing login page crashes",
        "type": "episodic",
        "priority": 70,
        "source_message_ids": ["msg-004"]
      },
      {
        "content": "User wants tests added when fixing bugs",
        "type": "instruction",
        "priority": 80,
        "source_message_ids": ["msg-006"]
      }
    ]
  }
]
```

### 4.4 The Dedup Step (Why It Matters)

Without dedup, every extraction run would add duplicate or near-duplicate memories. After 10 sessions, you'd have 10 copies of "User uses PostgreSQL." Dedup prevents this.

**Two-phase dedup** (`l1-dedup.ts`):

**Phase 1 — Candidate recall (no LLM, fast):**
For each newly extracted memory, search existing L1 records for similar ones:
- If embeddings available: vector cosine search, top-K (e.g. top 5).
- If only FTS: BM25 keyword search, top-K.
- If neither: skip dedup entirely, store all.

**Phase 2 — LLM judgment (one call for all):**
If any memory has candidates, send ALL new memories + their candidates to the LLM in one batch call:

```
System: You are a memory conflict detector. For each new memory, compare
against existing records and decide: store / update / merge / skip.

New memories:
  [1] "User uses PostgreSQL" (episodic, priority 75)
  [2] "User wants tests for bug fixes" (instruction, priority 80)

Existing candidates:
  For [1]:
    - [mem-023] "User decided to use PostgreSQL" (episodic, priority 70)
  For [2]: (no candidates)

Output: JSON [{ index, action, merged_content?, merged_type?, merged_priority? }]
```

**LLM response:**
```json
[
  { "index": 1, "action": "merge", "merged_content": "User uses PostgreSQL for their database", "merged_priority": 75 },
  { "index": 2, "action": "store" }
]
```

Result: memory [1] is merged with existing `mem-023` (old deleted, new combined version inserted). Memory [2] is stored as new.

### 4.5 Why "Calling Franky's Own LLM Registry" Matters

In the original MemoryCore, the extraction pipeline has its own LLM client (`CleanContextRunner` / `StandaloneLLMRunner`) that makes independent OpenAI-compatible HTTP calls. This means:

- A **separate LLM API key** and model config for memory extraction.
- A **separate HTTP client** with its own retry/timeout logic.
- The memory extraction model might differ from the agent's main model (e.g. use a cheaper `gpt-4o-mini` for extraction while the agent uses `claude-sonnet-4`).

In the Zig embedded version, we **don't build a separate LLM client**. Instead, the extraction pipeline calls **franky's existing `ai.registry.Registry`** — the same registry the agent loop uses to talk to Anthropic/OpenAI/Gemini/etc. This means:

```zig
// In agent-memory-zig's pipeline/extractor.zig:
pub fn extractL1(
    self: *Extractor,
    messages: []const L0Record,
    iso: IsolationContext,
) ![]L1Record {

    // 1. Build the extraction prompt (pure string building, no LLM)
    const system_prompt = EXTRACT_MEMORIES_SYSTEM_PROMPT;
    const user_prompt = try buildExtractionUserPrompt(self.allocator, messages);

    // 2. Call franky's LLM — NOT a separate HTTP client
    //    self.registry is *const ai.registry.Registry, passed in from franky
    //    self.model is ai.types.Model, the same model the user configured
    var ch = try ai.registry.Channel.init(self.allocator, 16);
    defer ch.deinit();

    try self.registry.stream(.{
        .allocator = self.allocator,
        .io = self.io,
        .model = self.model,
        .context = .{
            .system_prompt = system_prompt,
            .messages = &.{.{ .role = .user, .content = user_prompt }},
            .tools = &.{},
        },
        .options = .{ .max_output_tokens = 4096 },
        .out = &ch,
    });

    // 3. Drain the stream into a message
    const response_msg = try ai.stream.drainToMessage(&ch, self.io, self.allocator, null, null, null);
    defer response_msg.deinit(self.allocator);

    // 4. Extract text from the response
    const response_text = try extractTextContent(self.allocator, response_msg);

    // 5. Parse JSON → scene-segmented memories
    const extracted = try parseExtractionResponse(self.allocator, response_text);

    // 6. Dedup (Phase 1: search existing L1, Phase 2: another LLM call)
    const decisions = try self.batchDedup(extracted, iso);

    // 7. Write to store
    for (decisions) |d| try self.store.upsertL1(d.record, null, iso);
}
```

**Benefits of this approach:**

1. **Zero new credentials.** The user's existing `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / etc. that franky already manages is reused. No `TDAI_LLM_API_KEY` env var, no separate config.

2. **Zero new HTTP code.** Franky already has a battle-tested HTTP client (`ai/http.zig`) with per-phase timeouts, retry logic, proxy support, and TLS. The extraction pipeline gets all of that for free.

3. **Model flexibility.** The user can configure extraction to use the same model as the agent (highest quality) or a cheaper model (cost-saving). This is a config field `extraction_model` that defaults to the agent's model but can be overridden — e.g. `--memory-extraction-model openai/gpt-4o-mini`.

4. **Single binary, single process.** No Node.js sidecar, no port management, no inter-process communication. The extraction LLM call is just another `registry.stream()` invocation inside the same process.

5. **Consistent behavior.** The extraction uses the same streaming, retry, error-handling, and logging infrastructure as the agent's main LLM calls. Bugs fixed in franky's HTTP client automatically benefit the memory pipeline.

**The tradeoff:** The extraction happens synchronously in the franky process. If the user is mid-conversation and extraction triggers, it competes for the LLM rate limit. The solution is to run extraction **asynchronously** — after session end, or in a background thread with a separate (cheaper) model. The original MemoryCore does this via a pipeline worker scanner; we'll do it with a simple background `std.Thread.spawn`.

### 4.6 When Does Extraction Run?

In MemoryCore, extraction is triggered by:
1. **After-tool-call hook** — every N tool-call/result pairs (configurable `forceTriggerThreshold`, default 4).
2. **Timer scanner** — periodic background scan for unprocessed L0 messages.
3. **Session end** — flush pending extractions.

For franky's embedded version, the simplest approach:
- **On session end** (when franky saves `transcript.json`): trigger extraction for all new L0 messages since last extraction.
- **Optionally**: a background timer every 5 minutes if the session is long-running.
- The extraction uses a **checkpoint** (`.metadata/checkpoint.json`) to track which L0 messages have been processed, so it only extracts new ones.

---

## 5. Franky Integration Points

### 5.1 System Prompt Injection (Recall → Bootstrap)

**Where:** `src/coding/modes/print.zig:339`:
```zig
const system_prompt = try buildSystemPromptIo(allocator, io, environ, cfg);
```

**Integration:** Before building the system prompt, call `memory.recall(query=user_prompt)` and prepend L2/L3/L1 results as a bounded context block:

```
<memory_context>
## Persona
User's name is Alice. Prefers concise answers. Uses PostgreSQL.

## Current Scenario
debugging auth module — found nil pointer in middleware, adding tests.

## Relevant Facts
- User wants tests added when fixing bugs (priority: 80)
- User decided to use PostgreSQL (priority: 75)
</memory_context>
```

### 5.2 Turn Capture (Write → L0)

**Where:** `src/agent/loop.zig` — after each turn, the transcript has new messages.

**Integration:** After a turn completes, call `memory.addConversation(messages, session_id)` to write to L0. This is a cheap SQLite INSERT — no LLM call, no network. Franky already saves `transcript.json`; the L0 capture piggybacks on the same hook.

### 5.3 Extraction Trigger

**Where:** Session end (or background timer).

**Integration:** On session end, spawn a background thread that runs the L1 extraction pipeline (Section 4). This calls franky's `ai.registry.Registry` to distill L0 → L1. The thread writes results to SQLite and exits.

### 5.4 Memory Search Tool (Optional)

**Where:** `src/coding/tools/` — register a `memory_search` tool so the agent can proactively query memory mid-conversation.

### 5.5 Compaction Synergy

Franky's **compaction** + **zompress** compress *within-session* context. The memory pipeline is **cross-session** — complementary, not overlapping. When a span is compacted, the original messages should be captured to L0 *before* they're lost.

---

## 6. Proposed Zig Implementation — `agent-memory-zig` (Embedded Only)

### 6.1 Repository Structure (mirrors zompress)

```
agent-memory-zig/
├── build.zig              # Package + tests
├── build.zig.zon          # Zero external deps (like zompress)
├── src/
│   ├── root.zig           # Public API re-exports
│   ├── types.zig          # L0Record, L1Record, ProfileRecord, IsolationContext
│   ├── isolation.zig      # IsolationContext, validation, default values
│   ├── store.zig          # MemoryStore interface (vtable)
│   ├── embedded/
│   │   ├── sqlite_store.zig  # SQLite + FTS5 for L0/L1 (the core store)
│   │   ├── bm25.zig          # FTS5 BM25 query builder + result scoring
│   │   ├── rrf.zig           # Reciprocal Rank Fusion (pure Zig, ~40 lines)
│   │   ├── vector.zig        # Brute-force cosine similarity (no sqlite-vec needed initially)
│   │   ├── embedding.zig     # OpenAI-compatible embedding HTTP client (optional)
│   │   └── profile.zig       # L2/L3 markdown file read/write + version sync
│   ├── pipeline/
│   │   ├── extractor.zig     # L1 extraction: builds prompt, calls LLM, parses JSON
│   │   ├── dedup.zig         # Batch dedup: candidate search + LLM conflict judgment
│   │   ├── prompts.zig       # Extraction + dedup prompt templates (ported from TS)
│   │   └── checkpoint.zig    # Track which L0 messages have been processed
│   └── util/
│       ├── hash.zig          # sha256 for stable IDs (std.crypto)
│       ├── json.zig          # JSON helpers (std.json)
│       └── token_counter.zig  # Heuristic token estimation (reuse zompress's)
├── vendored/
│   └── sqlite3.c            # SQLite amalgamation (public domain)
├── test/
│   ├── isolation_test.zig
│   ├── rrf_test.zig
│   ├── sqlite_store_test.zig
│   ├── extractor_test.zig
│   └── dedup_test.zig
└── README.md
```

### 6.2 Core Types (`types.zig`)

```zig
const std = @import("std");

pub const MemoryType = enum {
    persona,
    episodic,
    instruction,

    pub fn fromString(s: []const u8) ?MemoryType {
        if (std.mem.eql(u8, s, "persona")) return .persona;
        if (std.mem.eql(u8, s, "episodic")) return .episodic;
        if (std.mem.eql(u8, s, "instruction")) return .instruction;
        return null;
    }

    pub fn toString(self: MemoryType) []const u8 {
        return switch (self) {
            .persona => "persona",
            .episodic => "episodic",
            .instruction => "instruction",
        };
    }
};

pub const IsolationContext = struct {
    team_id: []const u8 = "default",
    agent_id: []const u8 = "default",
    user_id: []const u8 = "default",
    session_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
};

pub const L0Record = struct {
    id: []const u8,
    session_key: []const u8,
    session_id: []const u8,
    role: []const u8,           // "user" | "assistant" | "tool"
    message_text: []const u8,
    recorded_at: []const u8,    // ISO 8601
    timestamp: i64,              // epoch ms
    team_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

pub const L1Record = struct {
    record_id: []const u8,
    content: []const u8,
    type: MemoryType,
    priority: f32,
    scene_name: []const u8,
    session_key: []const u8,
    session_id: []const u8,
    team_id: []const u8,
    task_id: []const u8,
    user_id: []const u8,
    agent_id: []const u8,
    version: u32,
    timestamp_str: []const u8,
    timestamp_start: []const u8,
    timestamp_end: []const u8,
    created_time: []const u8,
    updated_time: []const u8,
    metadata_json: []const u8,
};

pub const SearchResult = struct {
    record_id: []const u8,
    content: []const u8,
    type: MemoryType,
    priority: f32,
    scene_name: []const u8,
    score: f32,
    // isolation fields for display
    session_id: []const u8,
    team_id: []const u8,
    user_id: []const u8,
    agent_id: []const u8,
};

pub const StoreCapabilities = struct {
    vector_search: bool = false,
    fts_search: bool = false,
};

pub const RecallResult = struct {
    persona: ?[]const u8 = null,      // L3 content
    scenario_files: []ScenarioFile,  // L2 content
    l1_results: []SearchResult,       // L1 hybrid search hits
    total_chars: usize,

    pub fn deinit(self: *RecallResult, allocator: std.mem.Allocator) void {
        if (self.persona) |p| allocator.free(p);
        for (self.scenario_files) |f| f.deinit(allocator);
        allocator.free(self.scenario_files);
        for (self.l1_results) |r| r.deinit(allocator);
        allocator.free(self.l1_results);
    }
};

pub const ScenarioFile = struct {
    path: []const u8,
    content: []const u8,
    version: u32,

    pub fn deinit(self: ScenarioFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};
```

### 6.3 Store Interface (`store.zig`)

```zig
pub const MemoryStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
        capabilities: *const fn (ctx: *anyopaque) StoreCapabilities,

        // L0 — raw conversations (no LLM, cheap)
        add_conversation: *const fn (
            ctx: *anyopaque,
            records: []const L0Record,
            iso: IsolationContext,
        ) anyerror!void,

        query_conversation: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            filter: L0QueryFilter,
            iso: IsolationContext,
        ) anyerror![]L0Record,

        search_conversation: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            query: []const u8,
            top_k: u32,
            iso: IsolationContext,
        ) anyerror![]SearchResult,

        // L1 — structured memories (populated by extraction pipeline)
        upsert_l1: *const fn (
            ctx: *anyopaque,
            record: L1Record,
            embedding: ?[]const f32,
            iso: IsolationContext,
        ) anyerror!bool,

        search_l1: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            query: []const u8,
            top_k: u32,
            iso: IsolationContext,
        ) anyerror![]SearchResult,

        query_l1: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            filter: L1QueryFilter,
            iso: IsolationContext,
        ) anyerror![]L1Record,

        delete_l1: *const fn (
            ctx: *anyopaque,
            record_id: []const u8,
            iso: IsolationContext,
        ) anyerror!bool,

        // L2/L3 — markdown files
        read_scenario: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            path: []const u8,
            iso: IsolationContext,
        ) anyerror!?ScenarioFile,

        write_scenario: *const fn (
            ctx: *anyopaque,
            path: []const u8,
            content: []const u8,
            iso: IsolationContext,
        ) anyerror!void,

        list_scenarios: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            path_prefix: ?[]const u8,
            iso: IsolationContext,
        ) anyerror![]ScenarioFile,

        read_core: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            iso: IsolationContext,
        ) anyerror!?[]u8,

        write_core: *const fn (
            ctx: *anyopaque,
            content: []const u8,
            iso: IsolationContext,
        ) anyerror!void,

        // Recall — the main entry point for prompt injection
        recall: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            query: []const u8,
            top_k: u32,
            iso: IsolationContext,
        ) anyerror!RecallResult,

        // Pipeline checkpoint
        get_checkpoint: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!Checkpoint,
        set_checkpoint: *const fn (ctx: *anyopaque, checkpoint: Checkpoint) anyerror!void,
    };

    // Convenience wrappers call vtable.fn(ctx, ...)
    pub fn deinit(self: MemoryStore) void {
        self.vtable.deinit(self.ctx);
    }
    pub fn capabilities(self: MemoryStore) StoreCapabilities {
        return self.vtable.capabilities(self.ctx);
    }
    // ... etc for each method
};
```

### 6.4 Embedded SQLite Store (`embedded/sqlite_store.zig`)

**SQLite access:** Zig 0.17-dev has no built-in SQLite binding. We link `sqlite3.c` (amalgamation, public domain) via `build.zig`:

```zig
// build.zig
const lib_mod = b.createModule(.{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
// Add sqlite3.c as a compiled object
const sqlite_obj = b.addObject(.{
    .name = "sqlite3",
    .root_module = b.createModule(.{
        .root_source_file = b.path("vendored/sqlite3.c"),
        .target = target,
        .optimize = optimize,
    }),
});
// Define SQLITE_ENABLE_FTS5 for full-text search
sqlite_obj.root_module.addCMacro("SQLITE_ENABLE_FTS5", "1");
sqlite_obj.root_module.addCMacro("SQLITE_ENABLE_JSON1", "1");
lib_mod.linkObject(sqlite_obj);
```

**Schema** (created on `init`):

```sql
-- L0: raw conversations
CREATE TABLE IF NOT EXISTS l0_conversations (
  record_id TEXT PRIMARY KEY,
  session_key TEXT NOT NULL,
  session_id TEXT NOT NULL,
  team_id TEXT NOT NULL DEFAULT 'default',
  user_id TEXT NOT NULL DEFAULT 'default',
  agent_id TEXT NOT NULL DEFAULT 'default',
  task_id TEXT NOT NULL DEFAULT '',
  role TEXT NOT NULL,
  message_text TEXT NOT NULL,
  recorded_at TEXT NOT NULL,
  timestamp INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_l0_session ON l0_conversations(session_id);
CREATE INDEX IF NOT EXISTS idx_l0_timestamp ON l0_conversations(timestamp);

-- L0 full-text search
CREATE VIRTUAL TABLE IF NOT EXISTS l0_fts USING fts5(
  message_text,
  content='l0_conversations',
  content_rowid='rowid'
);

-- L1: structured memories
CREATE TABLE IF NOT EXISTS l1_records (
  record_id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  type TEXT NOT NULL,           -- persona | episodic | instruction
  priority REAL NOT NULL DEFAULT 50,
  scene_name TEXT NOT NULL DEFAULT '',
  session_key TEXT NOT NULL,
  session_id TEXT NOT NULL,
  team_id TEXT NOT NULL DEFAULT 'default',
  task_id TEXT NOT NULL DEFAULT '',
  user_id TEXT NOT NULL DEFAULT 'default',
  agent_id TEXT NOT NULL DEFAULT 'default',
  version INTEGER NOT NULL DEFAULT 1,
  timestamp_str TEXT NOT NULL,
  timestamp_start TEXT NOT NULL,
  timestamp_end TEXT NOT NULL,
  created_time TEXT NOT NULL,
  updated_time TEXT NOT NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_l1_session ON l1_records(session_id);
CREATE INDEX IF NOT EXISTS idx_l1_type ON l1_records(type);

-- L1 full-text search
CREATE VIRTUAL TABLE IF NOT EXISTS l1_fts USING fts5(
  content,
  content='l1_records',
  content_rowid='rowid'
);

-- L1 vectors (optional, for embedding-based search)
-- Start with brute-force cosine in Zig; add sqlite-vec later if needed
CREATE TABLE IF NOT EXISTS l1_embeddings (
  record_id TEXT PRIMARY KEY REFERENCES l1_records(record_id) ON DELETE CASCADE,
  embedding BLOB NOT NULL,      -- f32[] packed as little-endian bytes
  dimensions INTEGER NOT NULL,
  provider TEXT NOT NULL DEFAULT '',
  model TEXT NOT NULL DEFAULT ''
);

-- Pipeline checkpoint
CREATE TABLE IF NOT EXISTS pipeline_checkpoint (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

**FTS5 triggers** (keep FTS index in sync with table mutations):

```sql
CREATE TRIGGER l1_ai AFTER INSERT ON l1_records BEGIN
  INSERT INTO l1_fts(rowid, content) VALUES (new.rowid, new.content);
END;
CREATE TRIGGER l1_ad AFTER DELETE ON l1_records BEGIN
  INSERT INTO l1_fts(l1_fts, rowid, content) VALUES('delete', old.rowid, old.content);
END;
CREATE TRIGGER l1_au AFTER UPDATE ON l1_records BEGIN
  INSERT INTO l1_fts(l1_fts, rowid, content) VALUES('delete', old.rowid, old.content);
  INSERT INTO l1_fts(rowid, content) VALUES (new.rowid, new.content);
END;
-- Same pattern for l0_conversations / l0_fts
```

**Hybrid search** (vector + FTS + RRF):

```zig
pub fn searchL1Hybrid(
    self: *SqliteStore,
    allocator: std.mem.Allocator,
    query: []const u8,
    top_k: u32,
    iso: IsolationContext,
) ![]SearchResult {
    var fts_results: []SearchResult = &.{};
    var vec_results: []SearchResult = &.{};
    defer {
        for (fts_results) |r| r.deinit(allocator);
        allocator.free(fts_results);
        for (vec_results) |r| r.deinit(allocator);
        allocator.free(vec_results);
    }

    // 1. FTS5 BM25 search
    if (self.capabilities.fts_search) {
        fts_results = try self.searchL1Fts(allocator, query, top_k, iso);
    }

    // 2. Vector cosine search (if embeddings exist)
    if (self.capabilities.vector_search) {
        const query_embedding = try self.embed(allocator, query);
        defer allocator.free(query_embedding);
        vec_results = try self.searchL1Vector(allocator, query_embedding, top_k, iso);
    }

    // 3. RRF merge
    if (fts_results.len > 0 and vec_results.len > 0) {
        return try rrf.merge(allocator, &.{ fts_results, vec_results }, top_k);
    }
    if (fts_results.len > 0) return fts_results;
    if (vec_results.len > 0) return vec_results;
    return &.{};
}
```

### 6.5 RRF (`embedded/rrf.zig`)

```zig
pub const RRF_K: u32 = 60;

pub fn merge(
    comptime T: type,
    allocator: std.mem.Allocator,
    lists: []const []const T,
    top_k: u32,
) ![]T {
    var map = std.StringHashMap(struct { item: T, score: f32 }).init(allocator);
    defer map.deinit();

    for (lists) |list| {
        for (list, 0..) |item, rank| {
            const score = 1.0 / @as(f32, @floatFromInt(RRF_K + rank + 1));
            const id = item.record_id;
            const gop = try map.getOrPut(id);
            if (gop.found_existing) {
                gop.value_ptr.score += score;
            } else {
                gop.value_ptr.* = .{ .item = item, .score = score };
            }
        }
    }

    // Collect + sort by score descending
    var entries = try allocator.alloc(
        struct { item: T, score: f32 },
        map.count(),
    );
    defer allocator.free(entries);
    var iter = map.iterator();
    var i: usize = 0;
    while (iter.next()) |entry| : (i += 1) {
        entries[i] = entry.value_ptr.*;
    }
    std.sort.block(@TypeOf(entries[0]), entries, {}, struct {
        fn lt(_: void, a: anytype, b: anytype) bool {
            return a.score > b.score;
        }
    }.lt);

    const result_len = @min(top_k, entries.len);
    var result = try allocator.alloc(T, result_len);
    for (entries[0..result_len], 0..) |e, j| {
        result[j] = e.item;
        result[j].score = e.score; // overwrite with RRF score
    }
    return result;
}
```

### 6.6 Extraction Pipeline (`pipeline/extractor.zig`)

This is where franky's LLM registry gets called. The key type:

```zig
const std = @import("std");
const ai = @import("ai");  // franky's ai module (passed in via build.zig dependency)

pub const ExtractorConfig = struct {
    /// The LLM model to use for extraction. Defaults to the agent's model.
    model: ai.types.Model,
    /// Max new messages per extraction call (default 20).
    max_messages_per_extraction: u32 = 20,
    /// Max background messages for context (default 10).
    max_background_messages: u32 = 10,
    /// Max memories extracted per call (default 50).
    max_memories_per_session: u32 = 50,
    /// Whether to enable dedup (default true).
    enable_dedup: bool = true,
};

pub const Extractor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *MemoryStore,
    registry: *const ai.registry.Registry,
    config: ExtractorConfig,
    http_client: ?*ai.http.Client = null,

    /// Run the full L1 extraction pipeline on new L0 messages.
    ///
    /// This is the "brain" of the memory system:
    ///   L0 (raw chat) → [LLM extraction] → L1 (structured facts)
    ///
    /// Steps:
    ///   1. Read new L0 messages (since last checkpoint)
    ///   2. Split into background + new
    ///   3. Build extraction prompt
    ///   4. Call franky's LLM registry (NOT a separate HTTP client)
    ///   5. Parse JSON response → scene-segmented memories
    ///   6. Dedup against existing L1 (vector/FTS search + LLM judgment)
    ///   7. Write to L1 store
    ///   8. Update checkpoint
    pub fn run(self: *Extractor, iso: IsolationContext) !ExtractionResult {
        const checkpoint = try self.store.get_checkpoint(self.allocator);
        defer checkpoint.deinit(self.allocator);

        // 1. Read new L0 messages since checkpoint
        const messages = try self.store.query_conversation(
            self.allocator,
            .{ .updated_after = checkpoint.last_processed_timestamp },
            iso,
        );
        defer self.allocator.free(messages);
        if (messages.len == 0) return .{ .extracted_count = 0, .stored_count = 0 };

        // 2. Split into background + new
        const split = splitMessages(messages, self.config.max_background_messages, self.config.max_messages_per_extraction);
        const background = messages[0..split.background_end];
        const new_msgs = messages[split.background_end..split.new_end];

        // 3. Build extraction prompt
        const system_prompt = EXTRACT_MEMORIES_SYSTEM_PROMPT;
        const user_prompt = try buildExtractionUserPrompt(
            self.allocator,
            new_msgs,
            background,
            checkpoint.last_scene_name,
        );
        defer self.allocator.free(user_prompt);

        // 4. Call franky's LLM registry
        const response_text = try self.callLlm(system_prompt, user_prompt);
        defer self.allocator.free(response_text);

        // 5. Parse JSON response
        const extracted = try parseExtractionResponse(self.allocator, response_text);
        defer self.allocator.free(extracted);

        // 6. Dedup
        const decisions = if (self.config.enable_dedup)
            try self.batchDedup(extracted, iso)
        else
            try self.storeAllDecisions(self.allocator, extracted);
        defer self.allocator.free(decisions);

        // 7. Write to store
        var stored: u32 = 0;
        for (decisions) |d| {
            switch (d.action) {
                .store, .update, .merge => {
                    const record = buildL1Record(d, iso);
                    _ = try self.store.upsert_l1(record, null, iso);
                    stored += 1;
                },
                .skip => {},
            }
        }

        // 8. Update checkpoint
        const last_msg = new_msgs[new_msgs.len - 1];
        try self.store.set_checkpoint(.{
            .last_processed_timestamp = last_msg.recorded_at,
            .last_scene_name = if (extracted.len > 0) extracted[extracted.len - 1].scene_name else checkpoint.last_scene_name,
        });

        return .{
            .extracted_count = @intCast(extracted.len),
            .stored_count = stored,
        };
    }

    /// Call franky's LLM — this is the key integration point.
    /// We use franky's ai.registry.Registry, NOT a separate HTTP client.
    fn callLlm(self: *Extractor, system_prompt: []const u8, user_prompt: []const u8) ![]u8 {
        var ch = try ai.registry.Channel.init(self.allocator, 16);
        defer ch.deinit();

        const context: ai.types.Context = .{
            .system_prompt = system_prompt,
            .messages = &.{.{ .role = .user, .content = user_prompt }},
            .tools = &.{},
        };

        try self.registry.stream(.{
            .allocator = self.allocator,
            .io = self.io,
            .model = self.config.model,
            .context = context,
            .options = .{ .max_output_tokens = 4096 },
            .out = &ch,
            .http_client = @ptrCast(self.http_client),
        });

        // Drain the stream into a message
        const response_msg = try ai.stream.drainToMessage(
            &ch, self.io, self.allocator, null, null, null,
        );
        defer response_msg.deinit(self.allocator);

        // Extract text content from the response
        return try extractTextFromMessage(self.allocator, response_msg);
    }
};
```

### 6.7 Prompts (`pipeline/prompts.zig`)

The prompts are **ported verbatim** from the TypeScript originals — they're language-agnostic text. The only Zig-specific part is building the user prompt with formatted messages:

```zig
pub const EXTRACT_MEMORIES_SYSTEM_PROMPT =
    \\<system prompt text copied from l1-extraction.ts>
;

pub const DEDUP_SYSTEM_PROMPT =
    \\<dedup prompt text copied from l1-dedup.ts>
;

pub fn buildExtractionUserPrompt(
    allocator: std.mem.Allocator,
    new_messages: []const L0Record,
    background_messages: []const L0Record,
    previous_scene_name: ?[]const u8,
) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    // Format: [Previous scene]: <name>
    //         [Background messages]: ...
    //         [New messages]: ...
    try buf.writer().print("【上一个情境】：{s}\n\n", .{previous_scene_name orelse "无"});
    try buf.appendSlice("【背景对话】（仅供理解上下文，严禁提取记忆）：\n");
    for (background_messages) |m| {
        try buf.writer().print("[{s}] [{s}]: {s}\n", .{ m.id, m.role, m.message_text });
    }
    try buf.appendSlice("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n");
    try buf.appendSlice("【待提取的新消息】（只从这里提取记忆！）：\n");
    for (new_messages) |m| {
        try buf.writer().print("[{s}] [{s}] [{s}]: {s}\n", .{ m.id, m.role, m.recorded_at, m.message_text });
    }
    return try buf.toOwnedSlice(allocator);
}
```

### 6.8 build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // SQLite3 amalgamation (vendored, public domain)
    const sqlite_obj = b.addObject(.{
        .name = "sqlite3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("vendored/sqlite3.c"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sqlite_obj.root_module.addCMacro("SQLITE_ENABLE_FTS5", "1");
    sqlite_obj.root_module.addCMacro("SQLITE_ENABLE_JSON1", "1");
    sqlite_obj.root_module.addCMacro("SQLITE_THREADSAFE", "1");
    lib_mod.linkObject(sqlite_obj);

    // Export the module
    _ = b.addModule("agent_memory", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "agent_memory",
        .root_module = lib_mod,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const test_bin = b.addTest(.{
        .name = "agent-memory-tests",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(test_bin);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    b.installArtifact(lib);
}
```

### 6.9 build.zig.zon

```zig
.{
    .name = .agent_memory,
    .version = "0.0.1",
    .fingerprint = 0x<random>,
    .minimum_zig_version = "0.17.0-dev",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "vendored",
        "test",
    },
}
```

### 6.10 Franky Integration

In franky's `build.zig.zon`:
```zig
.dependencies = .{
    .zompress = .{ ... },
    .agent_memory = .{
        .url = "https://github.com/fr12k/agent-memory-zig/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "agent_memory-0.0.1-<hash>",
    },
},
```

In franky's `build.zig`:
```zig
const am_dep = b.dependency("agent_memory", .{ .target = target, .optimize = optimize });
const am_module = am_dep.module("agent_memory");
franky_module.addImport("agent_memory", am_module);
```

In franky's `src/coding/memory.zig` (new integration module):
```zig
const agent_memory = @import("agent_memory");
const ai = @import("../ai/types.zig");

pub const MemoryConfig = struct {
    db_path: []const u8,           // e.g. "~/.franky/memory.db"
    data_dir: []const u8,           // for L2/L3 markdown files
    isolation: agent_memory.IsolationContext,
    extraction_model: ?ai.types.Model = null,  // null = use agent's model
};

pub const MemoryIntegration = struct {
    store: agent_memory.MemoryStore,
    config: MemoryConfig,

    pub fn init(allocator, config) !MemoryIntegration {
        const store = try agent_memory.embedded.SqliteStore.init(
            allocator, config.db_path, config.data_dir,
        );
        return .{ .store = store.toMemoryStore(), .config = config };
    }

    /// Called before buildSystemPromptIo — injects recalled memory.
    pub fn recallIntoPrompt(
        self: *MemoryIntegration,
        allocator: std.mem.Allocator,
        query: []const u8,
    ) ![]u8 {
        const result = try self.store.recall(
            allocator, query, 10, self.config.isolation,
        );
        defer result.deinit(allocator);
        return try formatMemoryBlock(allocator, result);
    }

    /// Called after session save — captures messages to L0.
    pub fn captureTurn(
        self: *MemoryIntegration,
        allocator: std.mem.Allocator,
        messages: []const ai.types.Message,
        session_id: []const u8,
    ) !void {
        const records = try messagesToL0(allocator, messages, session_id, self.config.isolation);
        defer allocator.free(records);
        try self.store.add_conversation(records, self.config.isolation);
    }

    /// Called on session end — runs L1 extraction in background.
    pub fn triggerExtraction(
        self: *MemoryIntegration,
        registry: *const ai.registry.Registry,
        model: ai.types.Model,
    ) !void {
        const extractor = agent_memory.pipeline.Extractor.init(
            self.store, registry, model,
        );
        // Spawn background thread
        const thread = try std.Thread.spawn(.{}, runExtraction, .{extractor});
        thread.detach();
    }
};
```

---

## 7. Phased Roadmap

### Phase 1: Storage + Retrieval (Data Plane) — ~3-4 days

**Goal:** Franky can store and retrieve memories from SQLite. No LLM calls yet.

**Deliverables:**
- `types.zig` — all L0/L1/L2/L3 record types + IsolationContext.
- `isolation.zig` — validation + defaults.
- `embedded/sqlite_store.zig` — SQLite + FTS5 for L0/L1, L2/L3 markdown files.
- `embedded/bm25.zig` — FTS5 query builder.
- `embedded/rrf.zig` — Reciprocal Rank Fusion.
- `embedded/vector.zig` — brute-force cosine (for when embeddings are enabled later).
- `embedded/profile.zig` — L2/L3 markdown read/write + versioning.
- `store.zig` — `MemoryStore` vtable + `SqliteStore` implementation.
- `util/hash.zig` — sha256 for stable IDs.
- Vendored `sqlite3.c` amalgamation + build.zig linking.
- Tests: RRF, FTS search, store CRUD, profile read/write.

**Integration in franky:**
- `memory.captureTurn()` after session save → L0 INSERT.
- `memory.recallIntoPrompt()` before system prompt → L1/L2/L3 recall.
- Config: `--memory-db ~/.franky/memory.db --memory-data-dir ~/.franky/memory/`
- At this point, L1 is empty (no extraction yet), but L0 capture + L2/L3 manual files work.

### Phase 2: L1 Extraction Pipeline — ~2-3 days

**Goal:** Automatic L0 → L1 distillation using franky's LLM.

**Deliverables:**
- `pipeline/prompts.zig` — extraction + dedup prompts (ported from TS).
- `pipeline/extractor.zig` — calls `ai.registry.Registry`, parses JSON, writes L1.
- `pipeline/dedup.zig` — candidate search (FTS/vector) + batch LLM judgment.
- `pipeline/checkpoint.zig` — track processed L0 cursor.
- `embedded/embedding.zig` — optional OpenAI-compatible embedding HTTP client.
- Tests: extraction response parsing, dedup decisions, checkpoint tracking.

**Integration in franky:**
- On session end: `memory.triggerExtraction(registry, model)` spawns background thread.
- Config: `--memory-extraction-model openai/gpt-4o-mini` (defaults to agent's model).
- The extraction runs asynchronously; user sees a log message like "Extracting memories...".

### Phase 3: L2/L3 Profile Synthesis — ~2 days

**Goal:** Automatic L1 → L2/L3 aggregation.

**Deliverables:**
- Port the L2 scene aggregation prompt (group L1 by scene_name, synthesize markdown).
- Port the L3 persona synthesis prompt (aggregate L1 persona-type memories into `persona.md`).
- Background timer: run profile synthesis every N sessions or on demand.

### Phase 4: Polish — ongoing

- `memory_search` agent tool (let the agent query memory mid-conversation).
- Cold-start import: read franky's historical `transcript.json` files → L0.
- Character budget capping in recall (prevent memory from overwhelming context).
- Multi-agent isolation (per-agent `agent_id` in IsolationContext).
- Embedding provider switching + reindex (like the TS version).

---

## 8. API & Schema Reference

### SQLite Schema (Summary)

```sql
-- L0: raw conversations
CREATE TABLE l0_conversations (
  record_id TEXT PRIMARY KEY,
  session_key TEXT, session_id TEXT,
  team_id TEXT, user_id TEXT, agent_id TEXT, task_id TEXT,
  role TEXT, message_text TEXT,
  recorded_at TEXT, timestamp INTEGER
);
CREATE VIRTUAL TABLE l0_fts USING fts5(message_text, content='l0_conversations');

-- L1: structured memories
CREATE TABLE l1_records (
  record_id TEXT PRIMARY KEY,
  content TEXT, type TEXT, priority REAL, scene_name TEXT,
  session_key TEXT, session_id TEXT,
  team_id TEXT, task_id TEXT, user_id TEXT, agent_id TEXT,
  version INTEGER, timestamp_str TEXT, timestamp_start TEXT, timestamp_end TEXT,
  created_time TEXT, updated_time TEXT, metadata_json TEXT
);
CREATE VIRTUAL TABLE l1_fts USING fts5(content, content='l1_records');

-- L1 embeddings (optional)
CREATE TABLE l1_embeddings (
  record_id TEXT PRIMARY KEY,
  embedding BLOB, dimensions INTEGER, provider TEXT, model TEXT
);

-- Pipeline checkpoint
CREATE TABLE pipeline_checkpoint (key TEXT PRIMARY KEY, value TEXT);
```

### File Layout

```
~/.franky/memory/
├── memory.db                    ← SQLite (L0 + L1 tables)
├── scene_blocks/                ← L2 markdown files
│   ├── debugging-auth-module.md
│   ├── setting-up-postgres.md
│   └── ...
├── persona.md                   ← L3 persona
└── .metadata/
    ├── checkpoint.json           ← pipeline cursor
    └── scene_index.json          ← scene name → file mapping
```

### Memory Types

| Type | What it captures | Example |
|------|-----------------|---------|
| `persona` | User preferences, traits, stable facts | "User's name is Alice, prefers concise answers" |
| `episodic` | Events, decisions, what happened | "Decided to use PostgreSQL instead of MySQL" |
| `instruction` | Constraints, rules, methods | "Never commit directly to main branch" |

### Recall Result Format (injected into system prompt)

```
<memory_context>
## Persona
User's name is Alice. Prefers concise answers. Uses PostgreSQL.

## Current Scenario
debugging auth module — found nil pointer in middleware, adding tests.

## Relevant Facts
- [episodic, p=75] User decided to use PostgreSQL for their database
- [instruction, p=80] User wants tests added when fixing bugs
- [persona, p=90] User prefers dark mode in editor
</memory_context>
```

---

## Conclusion

The embedded-only approach gives franky a **self-contained memory system** in a single binary, with SQLite as the persistence layer and franky's own LLM registry as the intelligence layer. The `agent-memory-zig` package owns the database (storage, retrieval, RRF, FTS5); franky owns the brain (LLM calls via the registry it already has). No Node.js, no external process, no separate API keys.

The L1 extraction pipeline is the conceptual core: it's what transforms a chat log into *understanding*. By calling franky's `ai.registry.Registry` instead of building a separate LLM client, the extraction gets all of franky's existing infrastructure (HTTP, retry, auth, streaming, error handling) for free, and the user needs zero additional configuration beyond what they already have.
---

## 9. Implementation Status (Phase 1)

_Updated during Phase 1 implementation._

### What's Done

Phase 1 (Storage + Retrieval data plane) is **complete and tested**:

- ✅ **Core types** (`src/types.zig`) — `MemoryType`, `IsolationContext`, `L0Record`, `L1Record`, `SearchResult`, `StoreCapabilities`, `RecallResult`, `ScenarioFile`, `Checkpoint`, `DedupDecision`, query filters. All with `deinit()` and round-trip tests.
- ✅ **Isolation** — five-dimensional tenancy (team/user/agent/session/task) with `whereClause()` SQL builder. Defaults to `"default"` for single-user mode.
- ✅ **SQLite C bindings** (`src/embedded/sqlite.zig`) — manual extern declarations (no `@cImport` in Zig 0.17-dev). Wraps `sqlite3_open_v2`, `exec`, `prepare_v2`, `step`, `bind_*`, `column_*`, `close`, `busy_timeout`, `errmsg`. ~280 lines.
- ✅ **SQLite store** (`src/embedded/sqlite_store.zig`) — full L0/L1 CRUD + FTS5 search + L2/L3 markdown files + checkpoint + recall. ~820 lines.
- ✅ **RRF** (`src/embedded/rrf.zig`) — Reciprocal Rank Fusion with deep-copy + sort. 5 unit tests covering empty/single/overlapping/disjoint/capped cases.
- ✅ **Store vtable** (`src/store.zig`) — `MemoryStore` interface with full vtable for future backend swap.
- ✅ **FTS5 schema** — `l0_fts` + `l1_fts` virtual tables with sync triggers (insert/delete/update).
- ✅ **Schema auto-creation** — `SqliteStore.init()` creates all tables, indexes, triggers, and detects FTS5 support at runtime.
- ✅ **WAL mode** + busy_timeout + 64MB cache + foreign keys — same PRAGMAs as the TS implementation.
- ✅ **L0 capture** — `addConversation()` with transaction-wrapped batch inserts.
- ✅ **L0 query** — `queryConversation()` with isolation filtering + `updated_after` cursor + limit/offset.
- ✅ **L1 upsert** — delete + insert pattern (for FTS sync), optional embedding blob storage.
- ✅ **L1 FTS search** — `searchL1Fts()` with BM25 scoring + isolation filtering.
- ✅ **L1 hybrid search** — `searchL1Hybrid()` (currently FTS-only; vector search deferred to Phase 2).
- ✅ **L2/L3 files** — `readCore/writeCore` for persona.md, `readScenario/writeScenario/listScenarios` for scene_blocks/*.md.
- ✅ **Recall** — `recall()` aggregates L3 + L2 + L1 with `total_chars` budget tracking.
- ✅ **Checkpoint** — `getCheckpoint/setCheckpoint` in SQLite table (serialize is implemented; parse is a stub for Phase 2).
- ✅ **Integration tests** (`test/sqlite_store_test.zig`) — 12 end-to-end tests: init/schema, L0 add+query, L0 updated_after filter, L1 upsert+FTS, L1 no-match, L1 upsert replaces, L3 write+read, L3 missing returns null, L2 write+read, L2 list, checkpoint, recall.
- ✅ **Unit tests** — 12 tests in types.zig + rrf.zig (MemoryType round-trip, IsolationContext whereClause, RRF merge cases).

**Total: 24 tests pass, 0 leaks.**

### Problems Found & Solutions

#### Problem 1: `@cImport` not available in Zig 0.17-dev
**Finding:** The standard `@cImport` + `@cInclude("sqlite3.h")` pattern doesn't work in Zig 0.17-dev (it was removed or is not yet stable).

**Solution:** Declared all SQLite C functions manually as `extern fn` in `src/embedded/sqlite.zig`. This is more verbose but works reliably and avoids header parsing issues. ~30 extern declarations covering open/close/exec/prepare/step/bind/column.

#### Problem 2: Zig 0.17-dev ArrayList API requires allocator per-call
**Finding:** `std.ArrayList.append()`, `.appendSlice()`, `.deinit()` all require the allocator as the first argument (unlike older Zig where the allocator was captured in the struct).

**Solution:** Pass `allocator` explicitly to every `append`/`appendSlice`/`deinit` call. The `whereClause()` method signature was updated to take `allocator` as the first parameter. All `buf.writer().print()` calls were replaced with `std.fmt.allocPrint` + `appendSlice` (since `writer()` doesn't exist on ArrayList in this version).

#### Problem 3: Filesystem API requires `std.Io` parameter
**Finding:** In Zig 0.17-dev, all filesystem operations (`createDirPath`, `openFile`, `createFile`, `readPositionalAll`, `writeStreamingAll`, `close`, `iterate`, `stat`, `deleteTree`) require an `std.Io` as the first argument. `std.fs.Dir.cwd` doesn't exist — it's `std.Io.Dir.cwd()`.

**Solution:** `SqliteStore` now takes `io: std.Io` in `init()` and stores it as a field. All fs operations use `self.io`. Tests create a `std.Io.Threaded` instance via `std.Io.Threaded.init(allocator, .{})` and pass `.io()` to the store. `file.close()` → `file.close(self.io)`, `file.read()` → `file.readPositionalAll(self.io, buf, 0)`, `file.write()` → `file.writeStreamingAll(self.io, bytes)`.

#### Problem 4: `std.mem.writeInt` doesn't accept `f32`
**Finding:** `std.mem.writeInt` is for integers only. The original code tried `std.mem.writeInt(f32, blob[...], v, .little)` which fails because `f32` is a float, not an `int`.

**Solution:** Used `std.mem.toBytes(v)` + `@memcpy` to pack f32 values into the blob buffer:
```zig
const bytes = std.mem.toBytes(v);
@memcpy(blob[i * 4 ..][0..4], &bytes);
```

#### Problem 5: Duplicate WHERE clause conditions
**Finding:** The `IsolationContext.whereClause()` method adds `AND session_id = ?` when `session_id` is set. But `queryConversation()` was *also* adding `AND session_id = ?` after calling `whereClause()`, producing `... AND session_id = ? AND session_id = ?` with only one bind value.

**Solution:** Removed the duplicate `session_id`/`task_id` clause additions in `queryConversation()`. The `whereClause()` method is the single source of truth for isolation conditions; the caller only adds non-isolation filters (`updated_after`, `time_start_ms`).

#### Problem 6: FTS5 query injection safety
**Finding:** Raw user search terms can contain FTS5 special syntax (`OR`, `AND`, `*`, `""`, parentheses) that could break or exploit the search.

**Solution:** `buildFtsQuery()` tokenizes the query on whitespace and wraps each token in double quotes, escaping internal double-quotes by doubling them (FTS5 convention). This treats all input as phrase queries, preventing syntax injection.

#### Problem 7: Scenario file path mismatch in `listScenarios`
**Finding:** `listScenarios` stripped the `.md` extension from filenames before passing to `readScenario`, but `readScenario` builds the path as `scene_blocks/{path}` — so it looked for `scene_blocks/scenario-a` instead of `scene_blocks/scenario-a.md`.

**Solution:** Pass the full filename (including `.md`) to `readScenario`.

### What's Deferred to Phase 2

- **L1 extraction pipeline** — the `pipeline/` directory is in the structure but not yet implemented. This requires calling franky's `ai.registry.Registry` and is the "brain" of the memory system (see Section 4).
- **Vector search** — `l1_embeddings` table exists in the schema and `upsertL1` can store embeddings, but `searchL1Vector` and brute-force cosine similarity (`vector.zig`) are not yet implemented. FTS-only mode works.
- **Checkpoint JSON parsing** — `serializeCheckpoint` works, but `parseCheckpoint` is a stub returning empty. Phase 2 will use `std.json` for proper parsing.
- **L0 FTS search** — `searchConversationFts` is implemented but not exposed via the vtable yet (only `searchL1` and `recall` are wired).
- **Character budget capping** — `RecallResult.total_chars` is computed but not used to cap the injected context. Phase 2 will add a `max_chars` parameter to `recall()`.

### Build & Test Commands

```bash
zig build              # Build the library
zig build test         # Run unit tests (types + RRF)
zig build test-integration  # Run integration tests (real SQLite DBs)
zig build test-all     # Run all tests
```

### File Inventory

| File | Lines | Purpose |
|------|-------|---------|
| `src/types.zig` | 345 | Core types + isolation + tests |
| `src/store.zig` | 175 | MemoryStore vtable interface |
| `src/root.zig` | 42 | Public API re-exports |
| `src/embedded/sqlite.zig` | 280 | SQLite C extern bindings |
| `src/embedded/sqlite_store.zig` | 820 | SQLite store implementation |
| `src/embedded/rrf.zig` | 250 | Reciprocal Rank Fusion + tests |
| `test/sqlite_store_test.zig` | 465 | Integration tests (12 tests) |
| `build.zig` | 80 | Build config + test targets |
| **Total** | **~2457** | |

---

## 10. Revised Phase 2 Design — Tool + Guardrail Hook (Not LLM Registry)

_Updated after Phase 1 PR merge and architecture discussion._

### 10.1 The Problem with "Calling Franky's LLM Registry"

The original Phase 2 plan (§4.5, §6.6) proposed that `franky-memory`'s extraction pipeline would call franky's `ai.registry.Registry` directly to distill L0 → L1. This means:

- `franky-memory` would depend on franky's `ai` module at build time.
- The extraction LLM call would happen **inside** the franky-memory package, using franky's HTTP client, retry logic, and streaming infrastructure.
- The extraction would run as a background `std.Thread.spawn` after session end.

**Problems with this approach:**

1. **Circular dependency risk.** `franky-memory` imports `franky`'s `ai` module, while `franky` imports `franky-memory` as a package. While Zig's module system can handle this (they're not truly circular — franky-memory imports a *type*, franky imports a *module*), it creates tight coupling and makes franky-memory harder to test in isolation.

2. **The LLM doesn't know about memory.** If the extraction runs as a background thread after the session ends, the agent itself never sees the extracted memories. It can't correct bad extractions, can't decide what's worth remembering, and can't use the memory mid-conversation.

3. **Double LLM cost.** The extraction call uses the same LLM the user is already paying for. If the agent could extract memories *as part of its normal turn* (via a tool), there would be no separate extraction call — the agent would just call the tool when it decides something is worth remembering.

4. **Inflexible trigger logic.** A background thread with a timer/checkpoint is a blunt instrument. The agent knows better than any heuristic when a task is done, when a decision was made, or when a fact was established.

### 10.2 The New Design — Agent-Driven Memory via Tools

Instead of franky-memory calling the LLM, **the LLM (agent) calls franky-memory via tools**. This inverts the control flow:

```
OLD:  franky-memory → calls LLM → extracts memories → writes to SQLite
NEW:  agent (LLM) → calls memory_extract tool → franky-memory writes to SQLite
```

The agent is the intelligence; franky-memory is the storage. The agent decides what to remember, when to remember it, and how to phrase it. franky-memory just stores and retrieves.

**Three components:**

1. **`memory_search` tool** — the agent queries memory mid-conversation.
2. **`memory_save` tool** — the agent saves a fact/decision/preference to L1.
3. **`memory_recall` context injection** — franky injects recalled memory into the system prompt before each turn (or session start).

Plus an optional **guardrail hook** that nudges the agent to save memory at certain lifecycle points (finish_task, end of session).

### 10.3 Tool Design

#### `memory_search` tool

The agent calls this to find relevant memories. It hits the SQLite FTS5 index.

```zig
// In franky's src/coding/tools/memory_search.zig (new file)
pub fn tool(ctx: *MemoryContext) at.AgentTool {
    return .{
        .name = "memory_search",
        .description =
            "Search persistent memory for relevant context from previous sessions. " ++
            "Use this when you need to recall user preferences, past decisions, " ++
            "or facts established in earlier conversations. " ++
            "Pass a natural language query; results are ranked by relevance.",
        .parameters_json =
            \\{"type":"object","required":["query"],"properties":{
            \\  "query":{"type":"string","description":"Natural language search query"},
            \\  "limit":{"type":"integer","description":"Max results (default 5)","default":5}
            \\}}
        ,
        .execution_mode = .parallel,
        .ctx = @ptrCast(ctx),
        .execute = execute,
    };
}

fn execute(
    tool: *const at.AgentTool,
    allocator: std.mem.Allocator,
    io: std.Io,
    _: []const u8,
    args_json: []const u8,
    _: *ai.stream.Cancel,
    _: at.OnUpdate,
) !at.ToolResult {
    const ctx: *MemoryContext = @ptrCast(@alignCast(tool.ctx.?));

    // Parse args
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch {
        return common.toolError(allocator, "invalid_args", "failed to parse JSON");
    };
    defer parsed.deinit();

    const query = parsed.value.object.get("query")?.string;
    const limit_obj = parsed.value.object.get("limit");
    const limit: u32 = if (limit_obj) |l| @intCast(l.integer) else 5;

    // Search L1 via FTS5
    const results = ctx.store.searchL1Fts(allocator, query, limit, ctx.iso) catch {
        return common.toolError(allocator, "search_failed", "memory search failed");
    };
    defer {
        for (results) |r| r.deinit(allocator);
        allocator.free(results);
    }

    // Format results as text for the agent
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    if (results.len == 0) {
        try buf.appendSlice(allocator, "No memories found.");
    } else {
        for (results, 0..) |r, i| {
            try buf.writer.print(allocator, "[{d}] ({s}, priority={d}) {s}\n", .{
                i + 1, r.type.toString(), @as(i32, @intFromFloat(r.priority)), r.content,
            });
        }
    }

    return .{
        .content = &.{.{ .text = .{ .text = try buf.toOwnedSlice(allocator) } }},
    };
}
```

#### `memory_save` tool

The agent calls this to persist a memory. It writes directly to L1 (no extraction LLM call — the agent IS the extractor).

```zig
pub fn tool(ctx: *MemoryContext) at.AgentTool {
    return .{
        .name = "memory_save",
        .description =
            "Save a fact, decision, preference, or instruction to persistent memory. " ++
            "This memory will be available in future sessions via memory_search. " ++
            "Only save information that is durable (not one-time), self-contained " ++
            "(makes sense without conversation context), and user or AI centric. " ++
            "Do NOT save transient state, temporary values, or chitchat.",
        .parameters_json =
            \\{"type":"object","required":["content","type"],"properties":{
            \\  "content":{"type":"string","description":"The memory text. Must be self-contained — readable without conversation context."},
            \\  "type":{"type":"string","enum":["persona","episodic","instruction"],"description":"persona=user preferences/traits, episodic=events/decisions, instruction=rules/constraints"},
            \\  "priority":{"type":"integer","description":"0-100, higher=more important. Default 50.","default":50},
            \\  "scene_name":{"type":"string","description":"Scenario label (e.g. 'debugging auth module'). Default empty.","default":""}
            \\}}
        ,
        .execution_mode = .parallel,
        .ctx = @ptrCast(ctx),
        .execute = execute,
    };
}

fn execute(...) !at.ToolResult {
    // Parse content, type, priority, scene_name from args
    // Build L1Record
    // Call ctx.store.upsertL1(record, null, ctx.iso)
    // Return "Saved: <content>" to agent
}
```

### 10.4 Context Injection (Recall into System Prompt)

This is not a tool — it's a franky integration point. Before the system prompt is built, franky queries the memory store and injects a bounded context block:

```zig
// In franky's src/coding/memory.zig (new integration module)
pub fn buildMemoryContext(
    allocator: std.mem.Allocator,
    store: *agent_memory.SqliteStore,
    query: []const u8,  // typically the user's first prompt
    iso: agent_memory.IsolationContext,
) !?[]u8 {
    var recall = try store.recall(allocator, query, 10, iso);
    defer recall.deinit(allocator);

    if (recall.total_chars == 0) return null;  // no memory

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<memory_context>\n");

    // L3 persona
    if (recall.persona) |p| {
        try buf.appendSlice(allocator, "## Persona\n");
        try buf.appendSlice(allocator, p);
        try buf.appendSlice(allocator, "\n\n");
    }

    // L1 facts
    if (recall.l1_results.len > 0) {
        try buf.appendSlice(allocator, "## Relevant Facts\n");
        for (recall.l1_results) |r| {
            try buf.writer.print(allocator, "- [{s}] {s}\n", .{
                r.type.toString(), r.content,
            });
        }
        try buf.appendSlice(allocator, "\n");
    }

    // L2 scenarios (if any)
    for (recall.scenario_files) |s| {
        try buf.writer.print(allocator, "## Scenario: {s}\n{s}\n\n", .{
            s.path, s.content,
        });
    }

    try buf.appendSlice(allocator, "</memory_context>");
    return try buf.toOwnedSlice(allocator);
}
```

This is called in `buildSystemPromptIo` (or just before it) in franky's mode drivers, with the user's prompt as the `query` to seed the FTS5 search.

### 10.5 The Guardrail Hook — Nudge the Agent to Save Memory

This is the "optional" part. The agent already has the `memory_save` tool and can call it whenever. But sometimes the agent forgets. A guardrail hook can nudge it.

Franky already has a guardrail system (`src/agent/guardrails/`). The `GuardrailState` has:
- `afterToolCall(tool, call_id, result)` — called after every tool execution.
- `betweenTurns(allocator, io, transcript, out)` — called between turns, can inject messages.

The hook would work like this:

```
Agent calls finish_task
  → guardrails.afterToolCall sees finish_task was called
  → guardrails.betweenTurns fires
  → checks: has the agent saved any memory this session?
  → if no: inject a synthetic user message:
    "Before finishing, use memory_save to persist any important facts,
    decisions, or preferences from this session for future reference."
  → return true (wants another turn) so the agent gets the nudge
```

This is a **soft nudge**, not a forced extraction. The agent can still finish without saving if it judges there's nothing worth remembering. The nudge just reminds it.

**Implementation in franky (not franky-memory):**

The memory guardrail would be a new optional component in franky's `src/agent/guardrails/` or a new `src/coding/memory_guardrail.zig`. It would be wired into `GuardrailState` or be a separate hook:

```zig
// In franky's src/coding/memory_guardrail.zig (new, optional)
pub const MemoryGuardrail = struct {
    session_has_saved: bool = false,
    nudge_count: u32 = 0,
    max_nudges: u32 = 1,

    pub fn afterToolCall(self: *MemoryGuardrail, tool: *const at.AgentTool) void {
        if (std.mem.eql(u8, tool.name, "memory_save")) {
            self.session_has_saved = true;
        }
    }

    pub fn betweenTurns(
        self: *MemoryGuardrail,
        allocator: std.mem.Allocator,
        io: std.Io,
        transcript: *at.Transcript,
        out: *at.AgentChannel,
        finish_task_triggered: bool,
    ) !bool {
        // Only nudge on finish_task, and only if no memory was saved.
        if (!finish_task_triggered) return false;
        if (self.session_has_saved) return false;
        if (self.nudge_count >= self.max_nudges) return false;

        self.nudge_count += 1;

        // Inject a synthetic user message nudging the agent to save memory.
        const nudge = "Before finishing, if there are any important facts, decisions, " ++
            "or user preferences from this session that would be useful in future sessions, " ++
            "please use the memory_save tool to persist them.";
        const content = try allocator.alloc(ai.types.ContentBlock, 1);
        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, nudge) } };
        try transcript.append(.{
            .role = .user,
            .content = content,
            .timestamp = ai.stream.nowMillis(),
        });

        // Emit a tool_update so the UI shows the nudge.
        // Return true = "give me another turn" so the agent sees the nudge.
        return true;
    }
};
```

This is wired into the loop alongside the existing guardrails:

```zig
// In franky's loop.Config (or GuardrailState):
memory_guardrail: ?*MemoryGuardrail = null,

// In the loop's betweenTurns:
if (config.guardrails) |gr| {
    const finish_triggered = gr.finish_task_state.triggered;
    if (config.memory_guardrail) |mg| {
        if (try mg.betweenTurns(allocator, io, transcript, out, finish_triggered)) {
            continue;  // give the agent another turn to save memory
        }
    }
}
```

### 10.6 Why This Is Better

| Aspect | LLM Registry (old) | Tool + Hook (new) |
|--------|-------------------|-------------------|
| **Who decides what to remember** | A separate extraction LLM call | The agent itself, during the conversation |
| **LLM cost** | Extra extraction call per session | Zero extra calls (agent uses tools it already has) |
| **Build dependency** | franky-memory depends on franky's `ai` module | franky-memory has zero dependencies; franky depends on franky-memory |
| **Extraction quality** | LLM sees raw L0, extracts blindly | Agent has full context, knows what was important |
| **Mid-conversation recall** | Not possible (extraction is post-hoc) | Agent calls `memory_search` any time |
| **Correctability** | Agent can't fix bad extractions | Agent sees what was saved, can update/merge |
| **Trigger flexibility** | Timer / checkpoint heuristic | Agent decides; guardrail nudges on finish_task |
| **Testability** | franky-memory needs franky's registry to test | franky-memory tests with SQLite only; tool tests with a faux provider |

### 10.7 Revised Phase 2 Deliverables

**In `franky-memory` (the package):**

1. **`store.zig` vtable additions** — expose `searchL1Fts`, `upsertL1`, `recall` through the vtable (already implemented in Phase 1 as `SqliteStore` methods; just need vtable wiring).

2. **`context.zig`** — a `MemoryContext` struct that bundles `*SqliteStore` + `IsolationContext`. This is the `ctx` pointer passed to tools. No dependency on franky.

3. **No extraction pipeline.** The `pipeline/` directory stays in the repo structure for future use but is not implemented. The agent IS the extraction pipeline.

**In `franky` (the harness):**

1. **`src/coding/tools/memory_search.zig`** — new tool, calls `store.searchL1Fts`.
2. **`src/coding/tools/memory_save.zig`** — new tool, calls `store.upsertL1`.
3. **`src/coding/memory.zig`** — integration module: `MemoryContext` setup, `buildMemoryContext()` for system prompt injection.
4. **`src/coding/memory_guardrail.zig`** — optional guardrail that nudges the agent to save memory on `finish_task`.
5. **`build.zig.zon`** — add `agent_memory` dependency.
6. **`build.zig`** — add `agent_memory` module import.
7. **Mode drivers** (`print.zig`, `interactive.zig`) — wire memory tools + context injection + guardrail.
8. **System prompt** — add a section explaining the memory tools:

```
## Memory Tools

You have access to persistent memory that survives across sessions:

- **memory_search**: Search for relevant memories from previous sessions.
  Use this when you need to recall user preferences, past decisions, or
  facts established in earlier conversations.

- **memory_save**: Save a fact, decision, preference, or instruction to
  persistent memory. Only save information that is:
  - Durable: not one-time or transient
  - Self-contained: makes sense without conversation context
  - User or AI centric: the subject is "User" or "AI"

When you finish a task, consider whether anything worth remembering happened.
If so, save it with memory_save before calling finish_task.
```

### 10.8 Revised Phase 2 Roadmap

1. **franky-memory: vtable wiring + MemoryContext** (~0.5 day)
   - Expose `searchL1Fts`, `upsertL1`, `recall` through `MemoryStore` vtable.
   - Add `MemoryContext` struct (store + iso, no franky dependency).
   - Tests.

2. **franky: memory_search + memory_save tools** (~1 day)
   - Two new tool files in `src/coding/tools/`.
   - Register in mode drivers.
   - System prompt section.
   - Tests with faux provider.

3. **franky: context injection** (~0.5 day)
   - `buildMemoryContext()` in `src/coding/memory.zig`.
   - Call in `buildSystemPromptIo` (or before it).
   - Config: `--memory-db ~/.franky/memory.db`.

4. **franky: memory guardrail** (~0.5 day)
   - `MemoryGuardrail` in `src/coding/memory_guardrail.zig`.
   - Wire into loop's `betweenTurns`.
   - Config: `--memory-nudge` (default off).

5. **franky: L0 capture** (~0.5 day)
   - Capture messages to L0 after each turn (cheap SQLite INSERT).
   - This gives the raw conversation log for future reference and
     potential offline extraction (if we ever add it back).

Total: ~3 days for Phase 2, split across both repos.

### 10.9 The Key Insight

The original TencentDB Agent Memory uses an **LLM-driven extraction pipeline** because it's a standalone service — it doesn't have an agent loop to piggyback on. It sees raw L0 messages and must run a separate LLM call to understand them.

Franky is an **agent harness** — it has the agent loop, the LLM, and the tool infrastructure. The agent is already "thinking" during the conversation. Asking it to save a memory via a tool is like asking a human "hey, write that down." It's natural, cheap, and high-quality because the agent has full context.

The guardrail nudge is the safety net — it reminds the agent to "write things down" before finishing, without forcing a separate extraction process. This is simpler, cheaper, and produces better memories than a blind post-hoc extraction.
