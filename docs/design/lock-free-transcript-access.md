# Lock-free transcript access for the web UI status bar

## Problem

The web UI's status bar shows per-session token usage (input tokens, output
tokens, tool-call counts) after each turn. To collect this data the frontend
fetches `GET /transcript` when it receives the `turn_end` SSE event.

There is a race condition:

1. The agent loop acquires the **exclusive** `run_mutex` for the entire
   duration of `runOneTurnInternal` — both the worker thread (LLM call) and
   the main-thread event drain.
2. When the `turn_end` event is broadcast to SSE subscribers (line 2283 of
   `proxy.zig`), the exclusive lock is still held.
3. The browser immediately fetches `GET /transcript`.
4. The handler attempts `tryLockShared` — this **fails** because the
   exclusive lock is still held.
5. A `503 Transcript locked; retry` is returned.

### Attempted fix 1 (frontend retry — superseded)

The frontend retried `/transcript` on 503 (up to 5× at 200ms intervals).
This worked when the lock hold-time was short (event drain only) but failed
once `persistSession` (disk I/O) also ran under the exclusive lock — the
1-second retry window exhausted before the lock released.

### Attempted fix 2 (boolean flag + early unlock — superseded)

The exclusive lock was released **before** `persistSession` via a boolean
flag + `defer` guard pattern. This eliminated the race but introduced a
new one: a concurrent turn (e.g. `/retry`) could start and call
`persistSession` while the first turn's `persistSession` was still writing
to disk, causing a data race on the transcript buffer and possible file
corruption.

## Implemented solution (v1.30, RwLock with shared/exclusive split)

`run_mutex` is `std.Io.RwLock`. The key insight: the **exclusive lock is
only needed during `persistSession`** — the disk write. The rest of the
turn (event drain, tool execution, LLM call) only needs a **shared lock**
to prevent a concurrent `/prompt` from starting. Multiple shared holders
are fine — `/transcript` reads proceed in parallel with the turn.

### Lock lifecycle

```
Turn execution (event drain, tool calls):
  lockSharedUncancelable  ← shared: serialises /prompt, allows /transcript
  ... run turn ...
  unlockShared

persistSession:
  lockUncancelable        ← exclusive: no other writer, /transcript queues
  persistSession(session)
  unlock

/transcript HTTP handler:
  lockSharedUncancelable  ← shared: blocks briefly if persistSession writing
  renderTranscriptForUi
  unlockShared
```

### Why this is safe

| Scenario | Lock state | Outcome |
|---|---|---|
| Turn A running, browser fetches `/transcript` | A holds **shared** | `/transcript` also acquires **shared** — proceeds immediately ✅ |
| Turn A persisting, browser fetches `/transcript` | A holds **exclusive** | `/transcript` blocks on `lockShared` until persist finishes (few ms) ✅ |
| Turn A persisting, Turn B `/retry` starts | A holds **exclusive** | B blocks on `lockSharedUncancelable` until A finishes — serialised ✅ |
| Turn A persisting, Turn B `/retry` reaches its own `persistSession` | A holds **exclusive**, B holds **shared** | B upgrades to exclusive after A releases — no concurrent writes ✅ |

### Code changes

1. **4 call sites** (`runPrompt`, retry worker, review worker, `/reset`):
   `lockUncancelable` → `lockSharedUncancelable`, `unlock` → `unlockShared`.
   Removed the `unlocked` boolean flag and `*bool` parameter threading.

2. **`runOneTurnInternal`**: after event drain, releases shared lock,
   acquires exclusive lock, runs `persistSession`, releases exclusive lock.

3. **`respondTranscript`**: `tryLockShared` + 503 fallback → blocking
   `lockSharedUncancelable`. No more 503 retries.

4. **Frontend** (`app.js`): retry loop kept as safety net for other code
   paths (e.g. `/reset` which holds exclusive lock during session swap).

### Lock guard safety

The `defer` pattern at each call site guarantees unlock on early returns:

```zig
session.run_mutex.lockSharedUncancelable(io);
defer session.run_mutex.unlockShared(io);
// ... body ...
```

No boolean flag needed — the shared lock is released on every exit path
(early return, normal completion, panic).

## Requirements for a lock-free solution (future)

The current RwLock approach is pragmatic but not lock-free. The `/transcript`
handler still acquires a shared lock — it just no longer competes with the
exclusive holder. Future work could eliminate the shared lock entirely:

1. **No blocking read** — the `/transcript` handler must never attempt to
   acquire `run_mutex` (shared or exclusive). The transcript must be
   readable without synchronisation with the agent loop.
2. **Consistency** — a reader sees a point-in-time snapshot of the
   transcript. Partial appends (a message mid-construction) are fine as
   long as the reader sees an atomic slice of the message list.
3. **No data races** — the Zig memory model is undefined on data races:
   any concurrent write + read to the same memory without synchronisation
   is UB, regardless of whether the types are "atomic" in hardware.
4. **Minimal allocation** — the hot path (event drain) should not allocate
   a copy of the transcript on every event. Ideally writes are lock-free
   and reads observe a consistent snapshot via an atomic pointer swap.
5. **Compatible with deinit** — the old snapshot must be safely reclaimable
   after the next swap. The agent loop owns the allocator; the HTTP
   handler borrows a reference. Ownership and lifetime must be explicit.

## Design sketches

Below are three approaches. Each is a sketch — the implementation details
(ABA safety, memory ordering, allocator wiring) would need a prototype and
a concurrency-memory-model review before committing.

### A. Double-buffered transcript with atomic swap

Maintain two transcript buffers (`T0`, `T1`). An atomic `u1` index selects
the "active" buffer.

- The agent loop writes into the inactive buffer (append-only). After each
  append, it issues an atomic store to swap the active index.
- The HTTP handler reads from the active buffer under the atomic index.
- The old buffer (now inactive) is cleared before the next write cycle.

**Pros:**

- Truly lock-free on the read side.
- No allocation on the hot path after initial setup.

**Cons:**

- The agent loop must always write to the inactive buffer, which requires
  knowing which buffer is active at the moment of write — an atomic load
  before every append. This adds a load to every `transcript.append()`.
- Two full-size transcript buffers double memory usage for the transcript.
- Clearing the old buffer after swap risks a race if a concurrent read is
  still traversing the old buffer's message pointers. Needs RCU-style
  grace period or a generation counter.

### B. Snapshot-on-drain with atomic pointer

During the event drain, each message is redundantly serialised into a JSON
string buffer. When `turn_end` fires, the completed JSON is atomically
swapped into a `?*[]u8` that the HTTP handler reads.

- The agent loop builds a running JSON array of message objects alongside
  the in-memory transcript. Each `message_end` appends to this JSON buffer
  (no locking — single producer).
- At `turn_end`, an atomic store publishes the pointer to the completed
  JSON string.
- `GET /transcript` reads the atomic pointer, copies or borrows the string,
  and responds.

**Pros:**

- No shared-lock attempt at all.
- The JSON is already formatted for the UI — no per-request serialisation.
- The in-memory transcript (`transcript.messages`) becomes purely an
  internal concern of the agent loop; the HTTP handler never touches it.

**Cons:**

- Duplicates the serialisation work (once for the SSE `message_end` event
  downstream, once here).
- The JSON snapshot is a single large allocation per turn; if the session
  lives for thousands of turns, memory grows unbounded unless old
  snapshots are reclaimed.
- Ownership of the snapshot: the agent loop allocates it, but the HTTP
  handler needs to either copy it (defeating the purpose) or borrow it
  under a lifetime contract.

### C. Sequence-numbered immutable messages + atomically-published tail pointer

Each message is allocated independently and appended to a lock-free singly
linked list (or an `AtomicArrayList`). The head pointer is never touched;
a tail pointer is atomically advanced. Readers walk from a cached head to
the published tail.

- `Message` structs are allocated on the agent loop's allocator and
  contain a `next: ?*Message` field (or a `seq: u64` and the list is a
  contiguous `ArrayList` exposed through an atomic length counter).
- Before responding, `GET /transcript` reads the atomic length, snapshots
  the message count, and serialises in one pass.
- The agent loop appends after incrementing the atomic length so readers
  never see a partially-initialised message slot (write the data first,
  then `atomic.store(seq)` the new length).

**Pros:**

- Readers don't need a lock — they observe a consistent length through
  the atomic counter.
- No double buffering — memory is proportional to transcript size.
- Serialisation happens once per request, which is acceptable for a
  low-frequency endpoint (called once per turn).

**Cons:**

- The `ArrayList` + atomic length approach requires that the underlying
  storage never reallocates while a reader may be traversing. A growing
  `ArrayList` calls `realloc`, which invalidates pointers that a
  concurrent reader may hold. This can be avoided by pre-allocating the
  maximum expected transcript size (wasteful) or by using a linked-list
  of fixed-capacity chunks (a "segmented array").
- A linked-list of chunks adds pointer-chasing on the read side.
- If the agent loop `deinit`s an old message (e.g. during compaction)
  while a reader holds a reference, that's UB. Compaction must either
  be disabled when readers are possible or use a generation-based
  deferred-free scheme.

## Recommended direction: approach C with segmented storage

Approach C is the most natural fit for the existing code because it
preserves the existing `transcript.messages` `ArrayList` semantics while
adding an atomic guard for readers. The key change is replacing the
single `ArrayList` with a **segmented vector** — an array of fixed-
capacity chunks — so that appends never invalidate pointers to earlier
chunks.

### Sketch

```zig
const ChunkCapacity = 64;

const SegmentedTranscript = struct {
    chunks: []Chunk,
    chunk_count: usize,
    /// Atomically published count of messages visible to readers.
    /// Written by the agent loop after a complete append; read by
    /// the HTTP handler. When the handler reads `published_len`, it
    /// knows that at least that many messages are visible in the
    /// chunks (each chunk is written before the count advances).
    published_len: std.atomic.Value(usize),

    const Chunk = struct {
        messages: [ChunkCapacity]Message,
        len: usize, // messages in this chunk
    };
};
```

- The agent loop appends to the current chunk. When a chunk fills, a new
  chunk is allocated and appended to `chunks` (which may realloc, but
  realloc of the **chunk-pointer array** does not invalidate the chunks
  themselves — the old chunk pointers remain valid).
- After writing the message data into the chunk slot, the agent loop
  issues a `@atomicStore` (release ordering) to advance `published_len`.
- The HTTP handler reads `published_len` with `@atomicLoad` (acquire
  ordering), computes how many chunks to iterate, and serialises only
  those visible messages.
- Deferred deallocation: when compaction truncates the transcript, the
  old chunks are not freed immediately; instead they are pushed onto a
  freelist and freed only after a grace period during which no reader
  could still be traversing them (checked via an epoch counter or by
  waiting for the HTTP handler's request to complete via a channel).

### Open questions

1. **Segmented-vector overhead**: each chunk is a fixed-size allocation
   of `64 × sizeof(Message)`. For large sessions (thousands of messages)
   the chunk-pointer array grows. Is the pointer-chasing read overhead
   acceptable for a once-per-turn endpoint?

2. **Compaction + freed chunks**: when the agent loop truncates the
   transcript (e.g. on `/reset` or compaction), the removed messages may
   still be referenced by a concurrent reader. The freelist grace period
   needs a mechanism to know when all readers have finished — either a
   reader-count epoch (lock-free hazard-pointer style) or a simple
   per-request completion channel. Both add complexity.

3. **Allocator ownership**: currently the agent loop owns the allocator
   and deinits messages. Under the lock-free scheme, the agent loop must
   ensure that no reader can observe a freed pointer. This likely means
   never freeing individual messages — only entire chunks, deferred as
   described above.

4. **Snapshot consistency**: a reader that observes `published_len = N`
   must see all N messages fully initialised. This is guaranteed by the
   release-acquire ordering on the counter, but only if the writer
   finishes writing the message **before** the store. Compiler barriers
   (`@fence`) may be needed.

5. **Fallback for legacy consumers**: the existing `transcript` field on
   `Session` is used in other places (persistence, `/sessions/*/transcript`,
   `costHandler`). A lock-free refactor must either leave the old field in
   place (dual state) or migrate all consumers to the new storage. Dual
   state is safer for an incremental change.

## Non-goals

- Making `run_mutex` itself lock-free. The mutex serialises prompt
  dispatch, which is an intentional design property.
- Making every `transcript.append()` wait-free. The critical path is the
  HTTP handler; the writer can afford bounded pauses (chunk allocation,
  atomic store).

## See also

- `proxy.zig:respondTranscript` — now uses blocking `lockSharedUncancelable`.
- `proxy.zig:runOneTurnInternal` — upgrades to exclusive lock for persist.
- `web/app.js:refreshStatusLineUsage` — frontend retry safety net.
- Zig issue [#13267](https://github.com/ziglang/zig/issues/13267) — atomic
  memory model discussion (tracking for correctness review).
