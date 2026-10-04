# Distributed storage qualification (#522)

[Issue #522](https://github.com/reardan/w/issues/522) builds on the reliable
services foundations. This implementation changes libraries and tests; it
adds no syntax, compiler backend, on-disk WAL format, or clock-based lease.

## Faultable storage

`wal_open_policy_with_ops`, `wal_reader_open_with_ops`,
`raft_wal_open_policy_with_ops`, `lsm_open_policy_with_ops`, and the SSTable
constructors borrow a `file_ops*`. It must outlive the handles and any read
views. A null table selects native I/O; existing constructors preserve that
behavior. File creation, reads, writes, seek, truncate, file sync, replacement,
rename, directory sync, and cleanup all use this adapter. Checkpoints use the
same LSM generation publication path as snapshots.

The new seek/truncate operations support single-owner cursors. Concurrent
positional I/O remains in `lib/fs.w`. Short transfers and EINTR are handled by
checked loops. Zero progress is an error. A read error is not an EOF and must
not turn a good WAL into a torn tail or cause recovery to remove a referenced
SSTable. `wal_reader.failed` must be checked by replay owners. WAL sync includes
its parent directory, so an acknowledged first append cannot lose its name.

Publication remains file sync → rename → directory sync. A failure before
rename retains the old generation. A failure after rename reports
`fs_replace_report.renamed == 1`, poisons the live handle, and means **unknown
outcome**, not rollback. Stop using the owner and reopen/recover before retry.
`raft_wal_persist_release` gates all protocol output, including read probes,
read replies, snapshot progress, and the final snapshot acknowledgment.

`storage_fault_test` runs the real algorithms against `fake_fs`: ENOSPC,
EIO, EINTR, short/zero writes, seeded torn tails, failure at every operation
in a flush and snapshot publication, and withheld Raft replies. The fake
models power loss with ordered metadata and prefix/torn dirty writes; it does
not claim to model every physical device reordering. A stalled real sync is
covered separately by `storage_executor_test`.

`storage_native_test` starts independent processes for every mutation and
recovery. When `strace` is installed it injects syscall errors and SIGKILL
around write, fsync, and rename. It reports a skip explicitly if strace is
unavailable. SIGKILL exercises process crashes with the kernel page cache
still present; it is not a physical power-loss test.

## Bounded snapshot protocol

Raft sends snapshots over 32 KiB as stop-and-wait chunks. Each carries sender,
receiver, current term, snapshot index/term, full membership, total length,
whole-blob checksum, offset, payload length, and a checksum covering both the
chunk header and payload. Checksums use the existing portable truncated
SHA-256 convention; they detect accidental corruption and do not authenticate
peers. The old single-message encoding remains for small snapshots.

Wire types 5/6 are read probe/reply; 7/8 are snapshot chunk/progress ACK. Old
peers reject these new types, so clusters using the new features require a
coordinated upgrade. Existing message layouts and persisted formats stay the
same. Progress ACKs echo the request offset; delayed ACKs cannot move a newer
transfer backward. Raft's normal heartbeat retries resend the current chunk.
TCP reconnect drops any partially sent frame suffix, since a new stream must
begin on a frame boundary. The protocol retransmits the full chunk.

The receiver stages one snapshot, capped at 8 MiB and 1,024 members. Progress
is volatile: a receiver process restart, staging timeout (30 seconds), or loss
of staging requests offset zero. A socket reconnect preserves live staging;
duplicate chunks acknowledge the contiguous prefix. Conflicting identities,
gaps, stale terms, malformed lengths, checksum errors, and unrecognized senders
cannot publish partial state. Truncated frames are discarded at disconnect.
A newer identity starts only at offset zero. A complete whole-blob checksum
must pass before calling the ordinary install path. Its final ACK must still
pass durable Raft WAL publication; application publication uses `lsm_import`.

The 1 MiB frame limit is unchanged. Outbound queue limits still apply per peer;
configure at least 36 KiB to admit a maximum-size chunk and its membership
header (the default is 256 KiB). The inbox holds at most 256 messages and 2 MiB
of encoded payload, with bounded receive/accept work per pump and at most 64
inbound connections. A slow consumer must drain with `raft_tcp_recv` to release
backpressure. There is no unbounded inbound drain loop.

These are explicit size bounds, not a streaming arbitrary-size snapshot API.
The Raft/application APIs still own full blobs. During final install the old
snapshot, staging buffer, new Raft copy, pending application copy, and WAL
encoding can coexist. Services must budget those copies, log state, per-peer
queues, and per-connection accumulators in addition to the 8 MiB staging cap.
`raft_chunk_test` covers >1 MiB snapshots, corruption, duplicate delivery,
receiver restart, partial-frame reconnect, and slow loopback receivers with
concurrent log heartbeats under fixed inbox/outbound limits.

## Durable application and reads

`durable_apply.w` reserves `@raft/` keys in an LSM. The owner follows this order:

1. Persist Raft state before releasing its RPCs. Wait for commitment.
2. Check a stable request ID's retained result before computing a mutation.
3. Compute an application batch without external side effects.
4. `durable_apply_commit` publishes the batch, applied index/term, and retained
   result in one WAL record, then syncs it before returning success.
5. Release the response. If it is lost, retry the same request ID. A duplicate
   consumes its new log position but does not run its mutations again.

The adapter rejects skipped positions and regressing terms. Empty, rejected,
configuration, and logged-read commands still need a position-only batch.
`raft_pop_apply` means delivery, not durability: never use its `last_applied`
as proof that application effects are durable. On recovery use the persisted
application position to skip already published entries, while Raft commitment
is re-established normally. A failed application publication stops the apply
loop until recovery. Results remain until an explicit application retention
policy removes them; forgotten IDs must never be reused. This is a storage
transaction contract, not exactly-once external side effects. An external
consumer needs an idempotency key or a transactional outbox.

Export the **same store**, including reserved metadata, for a snapshot. Its
applied index/term must match the Raft boundary. After `lsm_import`, check
`durable_apply_snapshot_matches` before applying later commands or serving
reads. The legacy `kv_apply_pending` remains an idempotent put/delete example;
non-idempotent applications should use the new adapter contract.

`raft_read_begin` admits one barrier per leader and requires a committed entry
from the current term. Enable no-op-on-win or commit a command first. It takes
a committed index and sends term-scoped probes with a unique sequence. Distinct
current voters must confirm a majority. `raft_read_poll` then waits until the
caller's **durable application position** reaches that index, with no pending
snapshot. Success consumes the token. Read state on the same serialized owner.
An unavailable quorum, deadline, leadership/term change, or membership change
prevents success; no role-only shortcut or clock lease is used.

The argument is the standard quorum barrier: the current-term commit establishes
the leader's committed prefix; a majority responding to this newly issued
context establishes authority after read invocation; waiting for application
through the captured index makes that prefix visible. The history test uses
actual election/replication, persisted RPC gates, and durable application
batches. It checks an isolated old leader, a new leader committing more writes,
and a logged-read baseline. Other tests cover duplicates, stale replies,
application lag, concurrent writes, and timeouts. This is implementation and
history-test evidence, not a machine-checked proof of the entire Raft library.

## Maintenance and ownership

`storage_executor.w` reserves separate bounded executors for commit work and
bulk maintenance. Socket pumping and deadlines can continue while a task awaits
a worker. Admission charges retained bytes. A job exclusively owns its arguments
until the executor wait returns, even when cancellation arrives after dispatch.
Close cancels queued work; shutdown joins running syscalls before freeing state.
The integration test stalls a real maintenance sync, verifies a Raft commit can
still release its reply, fills the maintenance budget, cancels queued work, and
releases the stall before shutdown completes.

The LSM remains single-writer. Separate executors do not authorize concurrent
mutation of one tree, or Raft ticks while a worker persists that same Raft object.
Socket input waits in the bounded inbox until the serialized owner resumes.

The generation audit found that synchronous scans own their returned pages,
while internal merge cursors borrow live indexes and cannot survive mutation.
`lsm_view_new` adds an explicit read generation: independent table descriptors
and a copied memtable acquired on the serialized owner. Compaction may unlink
old names; pinned descriptors keep old values readable until `lsm_view_free`.
Views must not be mutated. Their admission checks retained file/memtable bytes;
services separately bound concurrent view count and RSS.

Message, batch, table-index and view cleanup also releases their owned container
buffers; memtable clear reuses its container capacity.

`lsm_compact_bounded` checks a conservative input-byte bound plus a complete
output Bloom filter/header allowance before creating a
temporary output. The existing SSTable writer buffers output, so this is a disk
space admission bound, not a streaming compactor or a strict heap budget.
`lsm_reclaim` examines a bounded slice of directory-list candidates and removes
only unreferenced exact `<prefix>.sst<digits>` names. Run it on the serialized
owner after recovery or failed cleanup. Advance the candidate cursor between
calls; retry failed unlinks. Never reclaim after an unknown publication outcome
until the owner has recovered. This supplies eventual orphan cleanup without
risking files referenced by the current manifest or pinned readers.

## Measurement

Run `./wbuild storage_probe`, then:

```sh
python3 tools/storage/bench.py --count 1000 --durability each --output bin/storage-bench.json
python3 tools/storage/bench.py --count 1000 --durability end --output bin/storage-bench-end.json
```

The JSON includes warm reads, requested-cold reads, scans, sustained updates,
compaction, recovery, and concurrent independent-store loads. It reports
throughput, p50/p95/p99 latency, per-child peak RSS, cumulative allocations,
read/write bytes/calls, sync time, context switches, queue bytes, logical write
amplification, and disk growth. Dedicated checksum and table-index decoding
phases separate those costs. The current SSTable format indexes records rather
than decoding compressed pages. Queue bytes are zero in this synchronous driver;
the executor integration tests qualify bounded asynchronous admission.

A local 300-key/32-byte-value run on 2026-10-04, syncing each update, measured
about 2.1k updates/s, 0.44 ms median update latency, 0.70 ms p99, and 1.61×
logical write amplification. Warm table reads had 7 µs median / 12 µs p99;
32 KiB checksum samples had 485 µs median; repeatedly decoding the 300-key
index had 234 µs median and 337 µs p99. These are small local baselines, not
capacity claims. The measured sync time dominated durable updates. Index
reopens allocated heavily. Cache eviction uses per-file POSIX_FADV_DONTNEED,
which is a request, not a guarantee of cold hardware. RSS and throughput include
process startup; latency samples exclude stdout formatting. Instrumentation
itself has cost. No CRC format change, page cache, buffer reuse, allocator,
runtime, or compiler optimization is enabled without a separate comparison.
