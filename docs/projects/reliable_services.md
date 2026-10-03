# W foundations for reliable storage and network services

Design: [issue #514](https://github.com/reardan/w/issues/514), proposed
2026-10-03 against commit `c6eaa9a066ff810fe65dc318b471f78ff22c4eb8`.
This file is the in-tree copy of that design plus the implementation
status. Source files are authoritative where this text and they differ.

## Implementation status

| Stage | Deliverable | Status |
|---|---|---|
| W0 | Checked I/O and stream repair | in progress |
| W1 | File durability primitives | in progress |
| W1a | WAL / LSM / persistence hardening | in progress |
| W2 | Bounded binary codecs | in progress |
| W3 | Bounded blocking executor | in progress |
| W4 | Clock and I/O simulation interfaces | in progress |
| W5 | Budgets and transport adapters | not started |
| W6 | Import roots and compiler hardening | not started |

## Goal

W already has the execution primitives needed for substantial services.
The highest-value next work is to make I/O failure, resource ownership,
durability, and overload behavior explicit. Most of this is ordinary W
library code: new concurrency syntax, a new compiler backend, and a
general ownership type system are not prerequisites. The existing
`libs/standard/distributed` libraries already provide storage and
protocol machinery that should be hardened and reused rather than
duplicated. Domain-specific replication, query planning and application
data models stay outside the base language; reusable protocol libraries
belong in `libs/standard/distributed`, not compiler syntax.

## Gaps this work closes

- `stream_flush` called `write` once, ignored the result, and cleared the
  buffered count; the large-write path in `stream_write` ignored its
  result too; `file_write_text` reported success without checking write
  or close; the reader treated a failed read as EOF, turning an I/O error
  into apparently valid truncated input.
- `task_write_all` handled partial writes and EAGAIN but had no EINTR or
  zero-progress policy and no transferred count on error.
- `wal_open` stopped silently at the first short, oversized or
  checksum-invalid record; `raft_wal_rewrite` and `lsm_compact` reset the
  live file before rewriting it (a destructive publication window);
  `lsm_flush` had no sync barrier between table/manifest publication and
  resetting the data log.

## P0 checked I/O and file durability (W0, W1)

`lib/io.w` defines an allocation-free result record:

```text
io_result = { transferred, status, native_error }
status = ok | eof | would_block | interrupted | cancelled |
         timed_out | no_space | unsupported | io_error

io_read_some / io_write_some / io_read_exact / io_write_all
```

Contracts: an empty request succeeds without touching the descriptor; EOF
after a partial read reports both EOF and the transferred count;
write-all advances only by confirmed progress and treats zero progress as
an error; EINTR is retried where the contract allows (cancellation is
checked between attempts in the task adapter); EAGAIN is returned by the
low-level API and awaited by the task adapter; a failure after progress
does not imply rollback. The platform errno is preserved next to the
portable category. `wresult[T]` is unchanged (its layout is part of the
`?` lowering).

Checked stream operations sit alongside the legacy signatures. A failed
flush retains the unwritten suffix, latches its error, and refuses new
bytes until the caller recovers or closes. Flush (copy to the OS), sync
(the durability barrier) and close (release + report; not a sync) are
distinct. A failed `close` is never retried on Linux: the descriptor is
already released and may be reused. Legacy void stream calls delegate to
the checked implementation and keep a queryable sticky error.
`file_write_text` reports write/close failure; a separate durable variant
syncs explicitly.

File operations, Linux x64 first, other architectures explicit
(unsupported targets return `IO_UNSUPPORTED`, never an emulation):

| Operation | Contract |
|---|---|
| Positional read/write | signed 64-bit offset, overflow rejected, shared file position untouched (`pread`/`pwrite`, never seek+write) |
| Truncate | length validated, failure reported, no durability claim |
| Exclusive create, directory-relative access | named flags, no check-then-create race (`O_EXCL`, `openat`) |
| Directory sync | reports whether directory-entry durability was established |
| Process-lifetime file lock | prevents concurrent owners; released on exit |
| Durable replace | temp sibling, full write, file sync, rename, parent dir sync |

Durable replace reports the failing stage and whether the rename already
happened: a directory-sync failure after rename means the new file may be
visible while crash durability is unknown. Durability claims assume a
local POSIX filesystem honoring `fsync` on files and directories (ext4,
xfs, btrfs); anything else must report an error rather than claim it.

### Storage hardening (W1a)

- WAL recovery gains a strict mode that reports the failure offset and
  distinguishes an incomplete trailing record from corruption inside the
  durable prefix; permissive truncation stays as an explicit policy.
- `raft_wal_rewrite` and `lsm_compact` publish through durable replace.
- `lsm_flush` orders table sync, manifest sync, directory sync, then
  data-log reset.
- Storage I/O failures become checked results at service boundaries; a
  persistence adapter withholds replies until required writes are
  durable, and a failed sync cannot release buffered success messages.

## P0 binary data and arithmetic contracts (W2)

`lib/bytes.w` grows rather than gaining a rival convention: borrowed
length-carrying byte views, an owned buffer with capacity/release/
transfer, and checked cursors for fixed-width integers (including 64-bit),
byte spans, length prefixes and varints. Every read checks the remaining
length first, every allocation checks its maximum and add/multiply
overflow, a malformed varint is an error, and safe decoders check even
with compiler bounds traps off. Borrowed views are invalidated when their
owner grows or frees. Wire and disk encodings never depend on native
struct layout, pointer size, padding or host endianness, and never
silently truncate an offset or identifier. Checked add/multiply and
narrowing helpers, with fixtures for high-bit constants, signed/unsigned
comparison, shifts and narrowing. CRC32C is distinct from CRC-32 (named
polynomials, incremental and known-answer tests; neither authenticates);
lazily built tables are initialized before workers start or under a
documented once mechanism. A byte-key map adapter handles arbitrary
binary keys with unsigned comparison and explicit ownership, with a
seeded hash option for untrusted keys; persisted formats never depend on
process-randomized hashes.

## P1 bounded execution (W3)

The task runtime stays. `task_spawn_blocking` keeps its
join-before-return guarantee (the argument may live on the waiting
task's stack). A reusable executor adds explicit limits on workers,
queued jobs and queued bytes; submission obtains capacity, awaits it
within a deadline, or returns overload. Separate executors serve
latency-sensitive sync and long maintenance work. Queued jobs can be
cancelled before dispatch; once a blocking syscall starts, cancellation
does not stop or undo it. Shutdown closes admission, drains or cancels
queued work, and joins in-flight workers before freeing queues. Event
loop dispatch bounds the callbacks processed per pass. No native mutex is
held across an await; cross-worker messages transfer owned buffers.

## P1 clocks and reproducible execution (W4)

A clock interface separates status from value and monotonic duration from
wall time, in explicit 64-bit units where the target has them (the
existing 32-bit `time_monotonic_ms` wraparound contract is kept and
documented). Event loops accept an instance-owned clock and poll provider
at construction; test providers advance virtual time and deliver
readiness deterministically. Wall-clock jumps never extend local
deadlines. Injectable file operations report write-completed and
sync-completed separately; a fake filesystem keeps volatile writes,
persists only permitted subsets, and drops volatile state on a simulated
crash, with short operations, EINTR, EAGAIN, ENOSPC, EIO, torn writes and
unsynchronized directory changes. This extends the existing simulator,
seeded PRNG and monotime helpers rather than competing with them.

## Later stages

W5 (allocator budgets, arenas, counters, a checked byte-transport
interface over TCP/Unix/TLS) and W6 (ordered `--import-root` resolution
for compile/check/deps/symbols, cache keys) are follow-ups. W0-W4 do not
depend on new async syntax, garbage collection, borrow checking,
io_uring, or a compiler IR.

## Open questions

- Which legacy stream callers migrate first; should unchecked helpers be
  deprecated?
- Can `?` propagation support allocation-free values without complicating
  the bootstrap ABI?
- Which filesystem/platform combinations satisfy durable replacement, and
  how is capability discovery exposed?
- What executor defaults keep throughput predictable under slow storage?
- Does a binary-key map need hash/equality hooks in built-in maps, or is a
  leaf library enough?
