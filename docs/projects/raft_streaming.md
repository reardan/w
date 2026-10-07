# File-backed Raft snapshots

Issue #589 adds a bounded streaming path alongside the compatible 8 MiB blob
API. A file snapshot can contain up to 256 MiB; increasing the blob limit is
not required. All bytes, including application position and retained request
results, remain opaque to Raft.

## Using the path

Configure a receiver before processing messages:

```w
raft_enable_snapshot_files(r, ops, scratch_prefix)
```

The prefix names a writable directory and filename stem. The file operations
adapter is borrowed and must outlive the Raft instance and its snapshots.
Native durability is supported on Linux x86/x64, like the existing WAL/LSM.
Temporary files are created exclusively with mode 0600 and immediately
unlinked. Their open descriptors retain the contents; process exit or restart
reclaims partial transfers without an orphan-file scan.

For the KV example, `kv_take_snapshot_file(r, store, scratch_prefix)` exports
sorted live records incrementally and compacts at `r.last_applied`. It returns
zero on a budget or I/O failure. Serialize the export with application writes:
the application state and applied index must describe the same instant.
`kv_apply_pending` automatically imports incoming file snapshots. This remains
the simple KV example's apply path, with the same semantics as its blob path.

Applications using the durable adapter should call
`durable_apply_install_pending(r, store)` before processing later entries or
serving reads. It checks the durable `@raft/applied` index and term in the unpublished
SST before publishing either representation, then clears the pending-snapshot
barrier. A mismatched boundary preserves the old application generation.
Failures retain the barrier and poison the store; stop and recover instead of
acknowledging application completion. Request results in `@raft/result/` travel
in the same generation as application data.

Applications with other state machines can use `snapshot_file_new`,
`snapshot_file_append`, `snapshot_file_seal`, `raft_take_snapshot_file`, and
`snapshot_file_read`. The Raft capture retains the sealed source; the caller
releases its reference with `snapshot_file_free`. An incoming source is available
as `r.pending_snap_file`, and must remain pending until the application's durable
install succeeds. `raft_take_pending_snapshot` is the legacy blob-only API.

## Transfer and resource bounds

The wire format remains chunk types 7/8. Every message carries at most 32 KiB
of payload, with one stop-and-wait offset per peer. Receivers admit one partial
transfer. Metadata binds sender, recipient, term, index, total length, digest,
and configuration to the existing chunk checksum. Duplicate chunks do not
append twice; missing/out-of-order chunks receive the contiguous offset.
Reconnection retransmits a chunk. Restart discards incomplete staging and
requests offset zero. Timeout frees the open scratch descriptor after 30 seconds.

SHA-256 is updated during each append. Completing a transfer processes at most
two SHA blocks, so the final chunk does not trigger a whole-file checksum scan
on the message-processing owner. The checksum remains the existing 32-bit
truncated SHA-256 integrity field, not an authentication mechanism; use the
separate authenticated transport for hostile networks.

Memory used by transfer payloads is independent of snapshot size: one 32 KiB
message payload, checksum scratch of at most 32 KiB plus configuration bytes,
and constant hash state per open file. There are no complete sender, receiver,
pending-install, or WAL payload copies. The current/pending source shares a
reference-counted descriptor. The unchanged TCP adapter's default outbound
budget is 256 KiB per peer; queue rejection requires retrying, never retaining an
unbounded extra application queue. Authenticated session writes apply their own
bounded frame/deadline contract.

The LSM streaming path enforces these additional limits before publication:

| Resource | Limit |
| --- | ---: |
| Individual value | 1 MiB |
| Individual key | 4096 bytes |
| Live records | 65,536 |
| Sum of key bytes | 4 MiB |
| Input SST merge cursors | 1,024 tables |
| Snapshot payload per file | 256 MiB |

Export holds one value at a time; import streams values through a 32 KiB buffer
straight into the unpublished SST. Bloom storage is capped at 128 KiB. The
resulting SST index is bounded by the key-byte and record limits, rather than
by payload size. Existing live LSM memory is outside this incremental budget.

Disk usage is bounded per stage: one current source and one incoming scratch
file per Raft node, each at most 256 MiB. Atomic publication temporarily retains
old and new WALs and old and new LSM generations. A streamed WAL adds 13 framing
bytes per 32 KiB chunk; the SST adds one byte per record relative to LSMX, plus
its bounded bloom. Caller-owned exports and retained references count as
additional explicit resources; release them promptly. These are library
admission budgets, not a filesystem quota for unrelated data or the retained
Raft log suffix.

## Persistence and publication

File-backed Raft snapshots use new WAL tags 5/6/7: BEGIN (index, term,
configuration, total bytes, hash), sequential CHUNK records (offset and up to
32 KiB), and END. All are written into the existing atomic WAL rewrite before
STATE and retained entries. Strict open rejects interrupted groups, invalid
sizes, gaps, and interleaved records. Recovery streams records into a new
unlinked source and checks the complete digest before exposing the recovered
Raft instance. WAL recovery automatically enables file staging using the WAL
path as the scratch prefix.

Continue to pass every outgoing response through `raft_wal_persist_release`.
A final successful installation reply is released only after the complete WAL
rewrite, file fsync, rename, and directory fsync. An I/O failure sets the Raft
snapshot failure flag or WAL failure flag and suppresses replies. Stop and
recover; do not retry on the poisoned instance.

LSM import validates all records while constructing an unpublished SST. It
uses the existing generation publication boundary: durable SST, atomic durable
manifest replacement, then data WAL epoch reset. Before manifest rename,
validation/I/O failures leave the old generation untouched. If directory sync
fails after rename, the store is poisoned and old files are retained for
recovery, which can select the complete old or new generation.

Export, LSM installation, and Raft WAL rewrite still perform work proportional
to total snapshot size. Schedule those operations on the serialized storage
owner, outside a shared socket-reactor callback; message chunk processing and
hash finalization themselves are bounded. This path provides bounded storage
and transfer memory, not a background storage scheduler.

## Qualification

`raft_stream_test` runs on x86 and x64. It transfers a 9.75 MiB LSM snapshot
without any whole-blob slot, interrupts and restarts the receiver, drops an ACK,
duplicates/corrupts chunks, and drives a second follower's normal replication
while the first catches up. The final reply passes the WAL durability gate;
the test closes/reopens Raft and the LSM and compares recovered binary values.
It also covers timeout cleanup, a mismatched whole-snapshot digest, an oversized
legacy message during active staging, snapshot append budgets, incremental
checksum boundaries, and application-position mismatch barriers.

Publication tests stop at file sync, rename, and directory sync for both the
Raft WAL and LSM manifest. A 69-cut injected I/O sweep exercises streaming LSM
installation and verifies old-or-new atomic recovery after a crash. Existing
blob snapshot, transport, WAL, KV, durability, simulator, and ownership tests
remain selected by the dependency-driven test picker.
