# W foundations for reliable storage and network services

Design: [issue #514](https://github.com/reardan/w/issues/514), proposed
2026-10-03 against commit `c6eaa9a066ff810fe65dc318b471f78ff22c4eb8`.
This file is the in-tree copy of that design plus the implementation
status. Source files are authoritative where this text and they differ.

The follow-up implementation and qualification for issue #522 are documented in
[Distributed storage qualification](distributed_followup.md).

## Implementation status

| Stage | Deliverable | Status |
|---|---|---|
| W0 | Checked I/O and stream repair | done: `lib/io.w`, `lib/stream.w`, `lib/file.w`, `lib/task_io.w` |
| W1 | File durability primitives | Linux x86/x64; native Darwin/APFS process-crash tests passed, ARM64 Linux qualification pending; see below |
| W1a | WAL / LSM / persistence hardening | done: `wal.w`, `raft_wal.w`, `lsm.w`, `sstable.w`, `kv_state.w`, `durable_gate.w` |
| W2 | Bounded binary codecs | done: `lib/bytes.w`, `lib/byte_buf.w`, `lib/checked.w`, `lib/byte_map.w`, `compress/crc32c.w` |
| W3 | Bounded blocking executor | done: `lib/executor.w` (+ `task_remote_call`) |
| W4 | Clock and I/O simulation interfaces | done: `lib/wclock.w`, `lib/event_loop.w` injection + dispatch limits, `lib/event_sim.w`, `lib/file_ops.w`, `lib/fake_fs.w`, `sim_env.w` |
| W5 | Budgets and transport adapters | done: `lib/arena.w`, `lib/metrics.w`, `lib/service_metrics.w`, `lib/transport.w`, `lib/transport_tls.w` |
| W6 | Import roots and compiler hardening | done: `--import-root`, build-cache keys, portable ordered atomic word access and fences |

- **W0.** `lib/io.w` defines `io_result` and the `IO_*` categories with
  the platform errno preserved. Stream writers keep the unwritten suffix
  and latch a sticky error until `stream_clear_error` or close; readers
  report read errors apart from EOF; checked flush/sync/close sit beside
  the legacy void calls, which delegate to them. `file_write_text`
  reports write/close failure; `task_write_all_result` /
  `task_read_exact_result` retry EINTR after a cancellation check and
  treat zero progress as an error.
- **W1.** `lib/fs.w`: `pread`/`pwrite` (63-bit signed offsets on 64-bit targets, 31-bit
  on i386), `ftruncate`, `openat` / exclusive create, directory fsync
  (`IO_UNSUPPORTED` when refused), `flock` process locks, and
  `fs_replace_durable` reporting the failing stage and whether the rename
  happened. ARM64 Linux and Darwin adapters are implemented. Darwin
  requires `F_FULLFSYNC` after filesystem sync; win64 and wasm remain
  unsupported.
- **W1a.** WAL recovery policies (permissive / strict / strict-truncate)
  with a report naming the first bad offset and classifying clean end,
  torn tail or interior corruption; a failed fsync poisons the handle.
  Raft log compaction, LSM compaction, the recovery manifest rewrite, the
  data-wal reset and snapshot install all publish through a synced
  `<path>.next` sibling, rename, then directory fsync. `lsm_flush` makes
  the table and its directory entry durable, then the manifest record,
  before resetting the data wal. Snapshot install builds an epoch-tagged
  generation before switching. `durable_gate.w` and
  `raft_wal_persist_release` hold replies until their writes are durable
  and drop them on a failed sync. `lsm_scan` (bounded, resumable) and
  `lsm_apply_batch` (one all-or-nothing WAL record) extend the ordered
  store. A failed reader open or read during Raft recovery returns null
  and releases the partially constructed node; a transient read-side
  failure leaves the WAL available for retry. Fault tests cover both
  voter and learner recovery.
- **W2.** 64-bit codecs as portable hi/lo halves, checked-word and native
  forms, never silently truncating; overflow-checked add/sub/mul,
  narrowing and allocation sizes on both word sizes; borrowed views,
  capped owned buffers and sticky-error reader/writer cursors with strict
  LEB128; CRC-32C with explicit table init (and the same rule documented
  for CRC-32); a binary-key map with copied keys, seeded HalfSipHash,
  limits and seed-independent sorted iteration, plus stable FNV-1a for
  persisted formats.
- **W3.** Reused workers with limits on workers, admitted jobs and
  admitted bytes; try-only or FIFO admission waits bounded by a timeout
  and the task deadline; join-before-return completion (a queued job is
  removed on cancellation, a dispatched one is waited out shielded and
  flagged); close / drain-or-cancel / join shutdown; counters. The
  memory-order contract of the existing atomics is in `threads.md`.
- **W4.** Instance-owned real and virtual clocks returning status apart
  from value; `event_loop_new_with(clock, poller)` with monotonic-only
  timers and per-pass dispatch limits with rotation; deterministic
  `event_sim` readiness; an injectable `file_ops` interface with a real
  adapter and a fake filesystem modeling write- vs sync-completion,
  ordered metadata journaling, seeded crashes with torn writes, lost
  unsynced renames and fsync-EIO data loss. `lib/fake_fs_async.w` adds bounded
  requests with separately delayed execution and completion notification,
  cancellation, crash invalidation, and event-loop/simulator clock adapters.
  Details:
  `docs/projects/simulation.md`.
- **W5.** Budgeted arenas with checked arithmetic and an explicit borrow
  count, bounded metrics (counters, log2 latency histogram, event ring,
  open-fd sampler), plus allocation-free scheduler, executor and allocation
  samplers in `lib/service_metrics.w`. The checked byte-transport interface
  has TCP/Unix and native TLS adapters. TLS verifies server identity,
  distinguishes timeout/cancellation from protocol failure, reports complete
  record progress, and owns socket shutdown. It supports task and ordinary
  thread callers; server-side client certificate authentication supports
  optional/required verification against a separate client trust bundle. TCP connection errors retain their native
  `SO_ERROR`. Contracts and tests are in `docs/projects/budgets_transport.md`.
- **W6.** `--import-root <dir>` (repeatable; `--import-root=<dir>` too)
  adds ordered import roots. Each import's module path is tried as
  `<root>/<path>.w` in each root in order, first root wins. After the
  roots, the unchanged default search runs: the working directory and
  its parents, then the compiler binary's directory and its parents.
  With no roots, resolution and every output are unchanged. Relative
  roots resolve against the working directory. `__arch__` resolves
  inside each root, and the auto-imported runtime resolves through the
  roots too.
  - Compile, `check`, `deps`, `symbols` and `defhash` take the option
    the same way, with either selector spelling.
  - `deps` prints the resolved files, and `deps --json` lists shadowed
    duplicates in a `"shadows"` array. This is never a warning, so
    `--strict` builds are unaffected.
  - Diagnostics name the resolved file. A bad root fails up front, and
    the cannot-locate message names the roots.
  - wexec and wtest closure ids carry a step's roots, so closures resolve
    the same files the compile does. Their digests also probe for new
    higher-priority files, so adding a shadowing file invalidates the
    cache key. wbuildd does not memoize root-carrying queries.
  - Details: `docs/projects/compilation_model.md` §7. Tests:
    `import_root_test`, `import_root_order_test` (plus their x64 twins)
    and `import_root_cli_test`.
  - Atomic acquire loads, release stores, relaxed word accesses and full
    fences work on x86/x64 and ARM64 Linux/Darwin, with compiler ordering
    barriers and explicit diagnostics for unsupported targets. The contract
    and architecture qualification are in `docs/projects/threads.md`.

The later fundamentals audit's builtin hashing and allocation changes landed
in #528 and #530. Checked printing now preserves partial progress and errors
through caller-owned results; legacy print helpers and builtin formatted
printing keep queryable sticky errors (see `docs/projects/golf_ergonomics.md`).
The original `task_xchan` wake race, unsigned comparisons and null TLS server
name follow-ups were fixed in #516. Chunked snapshot transfer is covered by
the #522 follow-up linked above.

Platform limits remain explicit: file durability is qualified on Linux
x86/x64. ARM64 Linux/Darwin adapters and native concurrent qualification
harnesses are implemented; native hardware/filesystem evidence is still pending
([qualification](arm64_qualification.md), [durability ports](durability_ports.md)).
Windows durability remains a separate, unsupported port. Thread-safe shared
budget accounting is available on Linux x86/x64, with single-owner arena
mutation unchanged. Checked transports expose kernel peer addresses, local Unix
credentials and directional shutdown ([socket identity](socket_identity.md)).
Native TLS supports optional/required client certificates with distinct client
trust and authenticated certificate fingerprints ([mutual TLS](mutual_tls.md)).

Tracked follow-ups: [native ARM64 qualification #607](https://github.com/reardan/w/issues/607),
[durability ports #608](https://github.com/reardan/w/issues/608),
[shared memory budgets #609](https://github.com/reardan/w/issues/609),
[socket peer identity and half-close #610](https://github.com/reardan/w/issues/610),
and [mutual TLS #611](https://github.com/reardan/w/issues/611).

Tracked follow-ups: [native ARM64 qualification #607](https://github.com/reardan/w/issues/607),
[durability ports #608](https://github.com/reardan/w/issues/608),
[shared memory budgets #609](https://github.com/reardan/w/issues/609),
[socket peer identity and half-close #610](https://github.com/reardan/w/issues/610),
and [mutual TLS #611](https://github.com/reardan/w/issues/611).

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
local filesystem honoring file and directory barriers (Linux ext4, xfs,
btrfs; Darwin/APFS as qualified below). A rejected barrier reports an
error rather than durability success.

### Darwin qualification (#608)

Run `./wbuild fs_durability_darwin_test` on an Apple Silicon Mac (also
included in `./wbuild tests_darwin`). It bootstraps the native compiler,
runs the shared `lib/fs_test.w` and `lib/io_test.w` suites, then runs
`tools/mac/test_fs_durability.py`. The generated Darwin twins remain
compile guards in Linux `tests`. Python 3 is needed for the fault harness.

Native validation on 2026-10-09: M3 Pro, macOS 26.3 (25D125), Darwin
25.3.0, local APFS on the internal Apple storage device. Fifteen filesystem
tests and five checked-I/O tests cover sparse offsets at 5 GiB, hole reads,
truncate, overflow rejection, two concurrent processes using the same open
file description while its cursor moves, exclusive creation, relative
open, close-on-exec, native errno, lock contention and release after
SIGKILL, file/directory barriers and replacement reports. Seventeen
additional cases inject errors at file barrier/rename/directory barrier
and SIGKILL immediately before and after those operations. They check
old/new visibility, temp cleanup or crash leftovers, `stage`/`renamed`,
and successful reopen/republication after ambiguous publication.

The fault harness shadows only the Darwin syscall adapter in a temporary
import root. `lib/fs.w` and its replacement algorithm are unmodified;
non-injected operations use real APFS syscalls. Barrier EIO, EINTR, EINVAL,
ENOTSUP and EOPNOTSUPP are propagated without fallback or retry. A
file-barrier failure preserves the old destination; a directory-barrier
failure reports `renamed=1`, so recovery must inspect the visible version
and republish/sync before acknowledging durability. Process death before
rename can leave a temp sibling; recovery must not treat it as published.

Darwin's raw syscall bridge negates errno without renumbering it. Checked
I/O now uses Darwin's numbers (e.g. EAGAIN=35, ENOTSUP=45, ENOSYS=78),
preserving them in `native_error`; Linux values remain unchanged. Darwin
ENOSYS stubs also use native 78. Both `fsync` and its `fdatasync` wrapper
require filesystem `fsync` followed by `fcntl(F_FULLFSYNC)`, including on
the parent directory after rename. This preserves the strict no-fallback
contract introduced in #616 for all callers, including stream/storage sync.

These are **process-crash and syscall-failure tests, not power-cut tests**.
Durability is conditional on the filesystem and device honoring both
barriers and atomic same-directory rename. APFS here accepts full barriers
on files and directories. Other filesystems, network mounts, external
controllers and devices that ignore flushes remain unqualified; rejected
barriers return an error, never success. Apple's [fsync documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html)
and [fcntl documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)
explain why a plain filesystem sync is insufficient for the drive cache.

ARM64 Linux native qualification remains open under #608. Windows needs
its own handle-sharing, locking, replacement and flush contract and native
crash tests; `lib/fs.w` continues returning `IO_UNSUPPORTED` there, without
claiming POSIX directory durability. This Darwin work does not complete
all of #608.

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
for compile/check/deps/symbols, cache keys) were planned as follow-ups,
and both have landed (status table above). W0-W4 do not depend on new
async syntax, garbage collection, borrow checking, io_uring, or a
compiler IR.

### W6 import roots (design text)

The existing resolution searches from the compiler's working directory
and has fallback behavior. Explicit ordered import roots are added as a
separately reviewed compiler feature, and they preserve the current
defaults. `--import-root` works the same way for compile, check, deps
and symbols, reports the resolved source, and enters build-cache keys.
Tests cover duplicate module names, root order and invocation from
different working directories. The feature needs no object files or
linker. Acceptance: reproducible imports, cache invalidation,
diagnostics, architecture checks and bootstrap fixpoints.

Decisions taken in the implementation:

- The roots come first, then the old search unchanged, rather than
  replacing it, so an empty root list is the old compiler exactly.
- A root is an exact location with no upward walk inside it.
- The roots also govern the auto-imported runtime: one rule for every
  import, and the runtime can be overridden.
- A shadowed duplicate is reported by `deps --json`, not warned about.

## Open questions (with what the implementation found)

- Which legacy stream callers migrate first; should unchecked helpers be
  deprecated? The legacy calls now delegate to the checked ones and keep
  a queryable sticky error, so migration can be gradual; storage and
  protocol writers should move first.
- Can `?` propagation support allocation-free values without complicating
  the bootstrap ABI? Not attempted; `io_result` is caller-owned instead.
- Which filesystem/platform combinations satisfy durable replacement, and
  how is capability discovery exposed? Linux x86/x64 on local POSIX
  filesystems, plus ARM64 Darwin on local APFS under the qualification
  above. Rejected barriers preserve native
  errors and map EINVAL/ENOTSUP/EOPNOTSUPP to `IO_UNSUPPORTED`.
- What executor defaults keep throughput predictable under slow storage?
  No implicit defaults. A sync class of 1-2 workers per device or log
  with a queue of about 4x workers, a byte cap equal to the dirty memory
  you will pin, and an admission timeout equal to the request budget; a
  maintenance class of 1 worker, queue 1, submitted try-only. Watch
  `rejected` / `wait_expired` and `queued_bytes`.
- Does a binary-key map need hash/equality hooks in built-in maps, or is a
  leaf library enough? A leaf library (`lib/byte_map.w`) is enough: the
  built-in `map[string, V]` is length-aware and now has seeded hashing
  from #528. Explicit size limits and seed-independent sorted iteration
  remain features of the leaf byte-key map. A per-table seed in
  `structures/hash_table.w` supplies the built-in protection.
