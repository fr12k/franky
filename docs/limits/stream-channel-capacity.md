# Stream channel capacity

The provider→reducer stream channel is the bounded ring buffer that
carries `StreamEvent`s from a provider's `streamFn` to the `runTurn`
drain loop. This doc explains the capacity choice, the deadlock that
the original sequential design could hit, and how to read the
`stream_channel_high_watermark` log line.

## History — the single-thread deadlock

Until the fix in this branch, `runTurn` called `registry.stream(...)`
synchronously and only drained the stream channel **after** it
returned — on the **same thread**:

```zig
// OLD (deadlock-prone) — producer and consumer on one thread
try config.registry.stream(.{ ..., .out = &stream_ch });
// only NOW does the drain start:
while (stream_ch.next(io)) |ev| { ... }
```

The provider pushes every SSE event into the bounded ring before the
drain loop runs. The ring has 16 384 slots. A large LLM response can
generate far more events than that:

| Response body | ≈ events (at ~60 B/event) | × capacity (16 384) |
|---------------|---------------------------|----------------------|
| 1 MB          | ~17 K                     | 1.0×                 |
| 4 MB          | ~67 K                     | 4.1×                 |
| 5.6 MB        | ~93 K                     | 5.7×  ← observed      |
| 5.8 MB        | ~96 K                     | 5.9×  ← observed      |

Once the ring fills, `Channel.push` blocks on `not_full.wait` — but
the drain loop that would pop events and signal `not_full` is on the
same thread and hasn't started. Classic bounded-channel deadlock.

### Why cancel/interrupt couldn't break it

- `Channel.push` is **uncancelable** (`waitUncancelable`). Firing
  `cancel` never wakes the blocked push.
- The HTTP SSE driver's cancel check only runs **between** events
  (`if (cancel.isFired())` in `driveSseFromBytes`). Once `push` blocks
  inside an event callback, control never returns to that check.
- `stop_requested_fn` is only checked at the **top of each turn**,
  which is never reached because the turn never finishes.

Symptom in `journalctl`: two large HTTP `response status=200
body_bytes=5…` lines, then total silence for minutes, and repeated
`POST /interrupt` requests that do nothing while the web UI's
`subscriber.added`/`subscriber.removed` cycles (the browser
reconnecting against a frozen agent).

## The fix — concurrent producer

`runTurn` now spawns the provider `stream` on a dedicated thread and
drains the channel concurrently on the main loop thread, mirroring
the existing `loopWorkerMain` fix for the agent→UI channel
(`agent.zig` v1.21.0):

```zig
// NEW — producer on its own thread, consumer on this one
const stream_thread = try std.Thread.spawn(.{}, streamWorkerMain, .{args});
defer { stream_ch.close(io); stream_thread.join(); }
while (stream_ch.next(io)) |ev| { ... }
```

The drain loop pops events as the producer pushes them, so the ring
only ever holds the events *in flight* (producer ahead of consumer),
not the whole turn's stream. A 5.6 MB response that used to need
~93 K slots now needs only whatever the producer gets ahead by —
typically a few hundred to low thousands, well under 16 384.

### Error-path safety

`runTurn`'s `defer { stream_ch.close(io); stream_thread.join(); }`
guarantees that on **every** exit path (normal completion, an error
from `out.push`/`reducer.apply`, or an early `return`):

1. The channel is closed — a producer still blocked in `push` on a
   full ring wakes with `error.Closed` and exits.
2. The producer thread is joined — no leak, no use-after-free of the
   borrowed `Context`/`StreamOptions` (the defer runs LIFO, before
   the `ctx_mut.deinit` that frees them).

`Channel.close` is idempotent, so the normal path (where the producer
already closed + returned) is a no-op + instant join.

## Reading the log line

After the drain completes, `runTurn` logs the **peak** channel depth
(max events in flight, sampled on each pop):

- `DEBUG stream_channel_usage peak=N/16384 (P%)` — healthy.
- `WARN  stream_channel_high_watermark peak=N/16384 (P%)` — the
  producer out-paced the drain and the ring got ≥75 % full. Not a
  deadlock under the concurrent design, but a sign the consumer
  (reducer + agent-event forward) is the bottleneck. If you see this
  routinely, the consumer side is the place to optimize, not the
  capacity.

## Capacity choice

16 384 slots at ~352 B/slot ≈ 5.5 MB. Under the concurrent design the
steady-state in-flight depth is far below the cap (the consumer
keeps pace); the cap only matters for brief producer bursts. 16 384
gives a ~3× margin over the observed ~5 300-event peak for a normal
turn (DeepSeek-v4-flash:cloud: ~1 K thinking + ~4 K text + overhead).
Going higher buys little under concurrency and costs memory; going
lower risks the producer briefly lapping the consumer on very large
reasoning turns.