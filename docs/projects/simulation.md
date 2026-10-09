# Clocks, injectable I/O and crash simulation

Stage W4 of the reliable-services design (issue #514,
`docs/projects/reliable_services.md`, "P1 clocks and reproducible
execution"), plus the event-loop dispatch bound from W3. Source files
are authoritative; this page is the map.

| Module | Role |
|---|---|
| `lib/wclock.w` | Clock interface: status-checked readings, monotonic vs wall, real and virtual clocks |
| `lib/event_loop.w` | `event_loop_new_with(clock, poller)`, `event_loop_set_dispatch_limits` |
| `lib/event_sim.w` | Scripted poll provider that advances a virtual clock instead of sleeping |
| `lib/file_ops.w` | Injectable file operations table + the real (syscall) adapter |
| `lib/fake_fs.w` | In-memory filesystem: volatile/durable state, seeded crashes, fault injection |
| `lib/fake_fs_async.w` | Bounded delayed read/write/sync requests with separate execution and notification events |
| `libs/standard/distributed/sim_env.w` | Per-node clock + fake filesystem for `sim.w` scenarios |

## Clocks (`lib/wclock.w`)

A `wclock` is a read function plus a self pointer. A reading returns an
`IO_*` status (`lib/io.w`) and writes the value through an out pointer:

```text
wclock_monotonic(c, &wtime) / wclock_wall(c, &wtime)     -> status
wclock_monotonic_ms(c, &int)                             -> status (wrapping)
wclock_monotonic_ns / wclock_wall_ms / wclock_wall_ns    -> status (IO_UNSUPPORTED if it does not fit)
```

- **Monotonic vs wall.** Monotonic time never goes backwards and is the
  only line deadlines may use. Wall time (epoch seconds) can step either
  way at any moment, independently.
- **Units.** `wtime {sec, nsec}` is the portable full-range value. On
  x64 `int` is 64 bits, so nanosecond and epoch-millisecond scalars fit;
  on 32-bit x86 they mostly do not, and the scalar readers return
  `IO_UNSUPPORTED` rather than a truncated number. Real wall seconds on
  x86 overflow in 2038 (i386 `clock_gettime` has a 32-bit `time_t`).
- **Millisecond contract.** `wclock_monotonic_ms` is exactly
  `time_monotonic_ms` (`lib/time.w`), read from a clock: word arithmetic
  that wraps a 32-bit int after ~24.8 days on x86. Compare such values
  only by difference (`libs/standard/distributed/monotime.w`).
- **Real clock** (`wclock_real_new`): `clock_gettime` with
  `CLOCK_MONOTONIC` / `CLOCK_REALTIME`.
- **Virtual clock** (`wclock_virtual_new`): moves only through
  `wclock_virtual_advance_ms/_ns/_to`; `wclock_virtual_jump_wall_ms` /
  `_set_wall` step wall time alone; `wclock_virtual_fail` makes readings
  fail with a chosen status.
- **Custom clocks** (`wclock_custom_new`): any read function, e.g.
  `sim_env.w`'s clock that follows `sim_now`.

Clocks are ordinary heap objects handed to their users. There is no
process-global hook, so two workers never race on shared clock state.
A virtual clock is not synchronized; one owner advances it.

Hybrid logical clocks (`libs/standard/distributed/clock.w`) encode
causality on top of a wall reading. They do not bound physical clock
uncertainty, and nothing in this stage does either. Lease and leader
logic still needs an explicit bound on clock drift.

## Event loop injection and fairness

`event_loop_new_with(clock, poller)` builds a loop that reads time from
`clock` and waits through `poller`. Pass 0 for either to get the default
(`time_monotonic_ms`, epoll or poll), so `event_loop_new` behaves as
before. A poller (`event_poller {wait, self}`, the `poll(2)` contract)
selects the poll backend. Timers read only the monotonic line, so a
wall-clock jump never extends or shortens a deadline. If an injected
clock fails to read, the loop holds time at the last good reading and
counts `clock_errors`.

`lib/event_sim.w` is the test provider. It delivers scripted one-shot
readiness (`event_sim_at`, `event_sim_after`) and level readiness
(`event_sim_set_ready`) on plain fd numbers, and never sleeps. When
nothing is ready, it advances the virtual clock to the earlier of the
loop's next timer deadline and the next deliverable scripted event. A
wait that nothing can ever wake returns `-EDEADLK`, which ends
`event_loop_run`.

`event_loop_set_dispatch_limits(loop, max_timers, max_fd_callbacks)`
bounds one pass. Both limits default to 0, which means unbounded and
keeps the current behaviour. Due timers left over fire next pass
without a sleep. Readiness left over is level-triggered, so it is
reported again:

- The poll backend starts the next pass at the first watch it did not
  reach.
- The epoll backend asks the kernel for at most `fd_limit` events. The
  kernel re-queues reported descriptors behind unreported ones.
- Always-ready synthetic slots (regular files) alternate with epoll
  events.

So a pass that hits the limit never starves later descriptors.

## File operations (`lib/file_ops.w`)

`file_ops` is a table of `open`, `close`, `read`, `write`, `sync`
(fsync), `datasync`, `rename`, `unlink`, `mkdir`, `sync_dir`, `seek` and
`truncate`. Each
fills an `io_result` and returns its status. `file_ops_write_all`,
`_read_exact` and `_read_to_end` loop over short transfers and retry
`IO_INTERRUPTED`. Write-completed (visible) and sync-completed (durable)
are separate steps. A name becomes durable only after its directory is
synced. The real adapter (`file_ops_real_new`) sits on the existing
syscalls; `sync_dir` opens the directory, fsyncs it and closes it.
Concurrent positional I/O remains in `lib/fs.w`; seek/truncate support
single-owner storage cursors through both real and fake adapters.

## Fake filesystem (`lib/fake_fs.w`)

Each file has volatile contents (what reads see), durable contents (as
of the last successful sync) and an ordered list of unsynced changes.
The namespace has a volatile view, a durable view and an ordered list of
unsynced directory operations.

- **Sync.** A file sync applies that file's changes to its durable
  copy. A directory sync commits metadata operations in order, up to the
  last one touching that directory (an ordered journal, like ext4 and
  xfs). Syncing a file does not make its name durable.
- **Failed sync.** An injected EIO on sync drops the unsynced changes:
  reads still see them, a crash loses them, and a later successful sync
  does not bring them back. This matches Linux after a writeback error.
- **`fake_fs_crash(fs, rng)`.** All descriptors become invalid. The
  crash keeps a seeded prefix of the unsynced directory operations.
  Then, per file, it keeps a seeded prefix of the unsynced changes. If
  that prefix stops before a write, a torn piece of that write may
  survive: the bytes up to a sector boundary. Files without a durable
  name are gone. `rng = 0` keeps nothing unsynced.
- **Faults.** Per-mille rates of short transfers, EINTR, EAGAIN, ENOSPC
  and EIO, for a chosen set of operations (`fake_fs_set_faults`). The
  nth following operation can be made to fail (`fake_fs_fail_nth`). A
  byte capacity cuts writes short and then fails them with ENOSPC.
- **Determinism.** Every decision comes from
  `libs/standard/distributed/prng.w`, so equal seeds and scripts give
  equal trace and state hashes on every target. `lib/fake_fs_test.w`
  freezes x86-observed values that the x64 twin must match.
- **Limits.** The crash model retains a prefix of issued unsynced writes;
  it does not model arbitrary device writeback reordering. Delayed execution
  and completion notification use the optional queue below.

`lib/file_ops_test.w` runs one scenario against the real adapter
(files under `bin/`) and the fake. It covers create, write, sync,
rename, directory sync, read-back, append, unlink and the common errors
(ENOENT, EEXIST, EBADF, EOF), and requires every status, errno, count
and byte to match.

## Delayed completion (`lib/fake_fs_async.w`)

The synchronous `file_ops` contract stays intact. Consumers that need to
exercise outstanding I/O submit explicit requests to a `fake_fs_async`
queue, which borrows a fake filesystem and its simulation clock:

```text
q = fake_fs_async_new(fs, clock, max_requests, max_bytes)
fake_fs_async_submit(q, FAKE_FS_OP_WRITE, fd, data, length,
                     execute_delay_ms, completion_delay_ms, &request)
```

Supported operations are one read, one write, file sync (the fake treats
datasync identically), and directory sync. For reads, pass a null data
pointer and the desired length; the request owns its read buffer. File sync
takes null data and zero length. Directory sync takes the directory's bytes
and length; the queue copies and terminates the path. Write data is also
copied, so the submitting buffer may be changed or released immediately.

Each request has **two events**. Execution applies the operation through
the existing fake `file_ops`, with its short transfers and fault injection.
Publication exposes the resulting status, native error and transferred
count after the completion delay. A file may therefore be visible or
durable while the caller still waits for its notification. Retries are new
requests, rather than invisible loops: an `EINTR` or `EAGAIN` can have its
own completion time and the test schedules the retry.

Advance the monotonic clock, then call `fake_fs_async_poll(q)`. It processes
due events in timestamp order, with submission order breaking ties, even
if one clock advance crosses several events. Explicit delays can be drawn
from the existing seeded PRNG. `fake_fs_async_next_delay(q, &delay)` returns
the delay to the next event, zero when already due, or -1 when idle. Use it
to arm an `event_loop` timer sharing the queue's clock, then poll and rearm
from that timer; other timer and readiness callbacks continue to run.
`sim_env_clock(env)` works too: after `sim_advance`, poll the queue. A failed
clock read prevents progress and is returned as an error. Wall time is
irrelevant. Combined delays are limited to 1e9 ms and polling gaps must be
less than 2^31 ms for wrap-safe comparisons on x86.

`fake_fs_async_result(q, request, &result)` returns `IO_WOULD_BLOCK` until
publication and `IO_OK` when the result is available. The **operation's**
status is in `result.status`, which can itself be `IO_WOULD_BLOCK`; result
availability and an operation returning EAGAIN are distinct. Only a
published successful sync may release a success reply. A successful write
alone establishes visibility, not durability. Submit dependent operations
after completion: the queue does not impose ordering by descriptor or turn
overlapping requests into a transaction.

Cancellation before execution prevents effects and completes with
`IO_CANCELLED`. Cancellation after execution sets `request.cancelled` but
waits for the scheduled notification and retains the actual operation
result. It cannot undo effects. `fake_fs_crash` and `sim_env_crash` invalidate
all unpublished requests on the next queue call, including executed syncs:
they complete with `IO_CANCELLED` and `request.crashed = 1`, never an old
success. The fake's ordinary crash rules determine which data survives.
Poll through the intended crash point before crashing to execute events
that should precede it; a crash itself does not catch up the event queue.

Admission bounds both request count and bytes (request records plus owned
buffers; bounded list pointer storage is additional). Completed requests
still count until `fake_fs_async_release`, which refuses unfinished work.
Reads expose bytes only through `result.transferred` after completion.
Keep descriptors open for outstanding operations. `fake_fs_async_free` is
simulation teardown: it discards remaining work without executing it and
invalidates all handles. Free it before the borrowed filesystem and clock.
The queue is single-owner and has no process-global state or callbacks
retaining caller memory.

`fake_fs_async_test` and its x64 twin cover visibility versus durability,
crashes before execution and before notification, cancellation on both
sides of execution, delayed errors and short transfers, buffer ownership,
queue limits, clock failure/wraparound/wall jumps, seeded schedules,
event-loop responsiveness, withheld replies on failed sync, and `sim_env`
crash integration. Existing `fake_fs_test` and `file_ops_test` continue to
qualify the underlying crash model and real-I/O parity.

## Simulator hook (`libs/standard/distributed/sim_env.w`)

`sim_env_new(net, node, seed, wall_base_sec)` gives one `sim.w` node:

- a clock whose monotonic time is `sim_now`, and whose wall time adds a
  per-node offset (`sim_env_jump_wall_ms`);
- a fake filesystem, which `sim_env_crash` power-cycles from a per-node
  seeded prng.

`sim.w` and the raft harness are unchanged.

## Deferred

- Positional-I/O entries in `file_ops`; concurrent positional I/O is
  currently provided separately by `lib/fs.w`.
- Moving `raft_sim_harness.w`'s real-file WAL onto `file_ops`. Raft WAL
  injection and algorithm-level fake-filesystem tests already landed in
  [the #522 follow-up](distributed_followup.md).
- Event-loop support for real descriptors and a virtual clock together;
  `event_sim` serves scripted descriptors only.
