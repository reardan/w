# Memory budgets, bounded diagnostics and the checked byte transport

Stage W5 of [issue #514](https://github.com/reardan/w/issues/514)
(design copy: `docs/projects/reliable_services.md`): "P1 memory budgets
and diagnostics" and "P2 transport". Reusable library interfaces:

| File | What it is |
|---|---|
| `lib/arena.w` | budgeted arena, single-owner `mem_budget`, concurrent `mem_shared_budget` |
| `lib/metrics.w` | fixed-size counters/gauges, log2 latency histogram, bounded event ring |
| `lib/transport.w` | checked byte-transport interface + TCP/Unix socket adapter |
| `lib/transport_tls.w` | TLS 1.3 adapter, verified server identity and optional/required client certificates |
| `lib/service_metrics.w` | allocation-free scheduler, executor and budget snapshots |

Tests: `lib/arena_test.w`, `lib/metrics_test.w`, `lib/transport_test.w`,
`lib/transport_tls_test.w`, `lib/service_metrics_test.w`,
`lib/shared_budget_test.w`, `lib/socket_identity_test.w`,
`lib/transport_mutual_tls_test.w`
(each with an x64 twin: `arena_64_test`, ...). The source files are
authoritative where this text and they differ.

## Arenas and budgets (`lib/arena.w`)

An arena allocates request-scoped objects from chunks taken from the
ordinary heap, so the existing per-thread heaps (`lib/thread_heap.w`)
and the guard-page debug allocator (`W_DEBUG_ALLOC`, `lib/memory_debug.w`)
apply to the chunks unchanged. The debug allocator sees whole chunks,
not individual arena objects; `arena_set_poison(a, 1)` fills the kept
chunk with `0xa5` on reset so a stale read shows a pattern instead of
old data.

Contract:

- **Every failure is a status, never an abort.** `arena_alloc(a, size,
  align, &p)` returns `ARENA_OK` or one of `ARENA_ERR_INVALID` (negative
  size), `ARENA_ERR_ALIGN` (not a power of two in 1..4096),
  `ARENA_ERR_OVERFLOW` (size + padding + header would overflow the word,
  or size > `ARENA_MAX_REQUEST` = 1 GiB on every target),
  `ARENA_ERR_BUDGET`, `ARENA_ERR_NO_MEMORY` (malloc returned 0). On
  failure nothing is allocated, `*p` is 0 and `alloc_failures` counts it.
  Arithmetic is checked (`arena_checked_add`) before any chunk size is
  computed.
- **The budget counts backing bytes** (chunk headers included) — the
  memory the process actually holds — not the bytes handed out. An
  optional `mem_budget` (`arena_set_shared_budget`) is charged the same
  bytes, so several arenas and plain allocations (`mem_budget_alloc` /
  `mem_budget_free`) can share one limit.
- **Borrowed views.** There is no escape analysis, so the borrow is an
  explicit count: code that hands arena memory to another task, a worker
  or an in-flight operation calls `arena_borrow`, and the holder calls
  `arena_release_borrow` when done. `arena_reset`, `arena_release` and
  `arena_free` return `ARENA_ERR_BORROWED` (and change nothing) while any
  borrow is outstanding. Allocation stays allowed: it never moves old
  objects. Releasing a borrow that was never taken is `ARENA_ERR_INVALID`.
- **Descriptors are freed separately from backing data.**
  `arena_reset` rewinds and keeps one default-size chunk, freeing every
  other chunk (oversized ones included), so memory held after a reset
  never depends on the largest burst. `arena_release` frees all chunks
  and leaves the descriptor valid and empty (counters kept).
  `arena_free` releases and then frees a descriptor from `arena_new`; a
  descriptor embedded in a struct or on the stack (`arena_init`) is never
  passed to it.
- Counters on the struct: `reserved`, `peak_reserved`, `bytes_used`,
  `peak_used`, `chunks`, `allocs`, `alloc_failures`, `resets`, `borrows`;
  `mem_budget` has `used`, `peak`, `failures`.
- **Single owner.** Arenas and `mem_budget` retain their inexpensive,
  unsynchronized behavior. Use one per worker or serialize their mutation.
  `mem_shared_budget` supplies separate concurrent accounting on Linux
  x86/x64; it does not make an attached arena thread-safe.

### Concurrent budgets (#609)

`mem_shared_budget_init` accepts a nonnegative limit (zero permits zero
bytes); `arena_int_max()` supplies the largest possible limit. Reserve and
release are atomic with respect to every operation on the descriptor.
A short CAS lock protects all counters, giving `mem_shared_budget_snapshot`
a coherent view of usage, peak, users and diagnostics. This is synchronized
accounting, not a lock-free algorithm: contended callers spin and must not
reenter it from a signal handler. No allocation or user callback runs under
the lock. Reservation overflow, exhaustion, invalid sizes and heap failures
have checked outcomes. Failed backing allocations roll back their reservation;
invalid releases leave other users' bytes intact. Reservation/allocation
failures and invalid releases have separate saturating counters.

Initialize a word-aligned descriptor before publishing it; never copy it.
Each worker retains a user with `mem_shared_budget_retain` before receiving
the pointer and calls `mem_shared_budget_drop` after its final operation.
The owner must stop admission of new callers before destroying, reinitializing
or freeing it. `mem_shared_budget_destroy` refuses outstanding users or
reserved bytes. A reference count cannot protect acquisition through an
already freed pointer. Raw reserve/release operations require callers to
track their own bytes, just like sized allocation/free pairs.

`arena_set_thread_budget` attaches a retained reference before allocation;
attach/detach requires no chunks or borrows and excludes a simultaneous
single-owner `mem_budget`. `arena_release` frees bytes but retains the
attachment for reuse. Explicitly detach a stack arena before reinitializing
it; `arena_free` detaches a heap descriptor automatically. Each worker owns
its own arena and its borrow/reset lifecycle remains unchanged.

`mem_shared_budget_alloc`/`free` charge heap allocations (zero size charges
one byte). `alloc_with` supports a caller-selected allocator and deterministic
failure injection; free that allocation with the matching allocator and
release its charged size. `metrics_sample_shared_budget` reads a coherent
failure snapshot; the metrics object still requires caller serialization.
`shared_budget_test` and its x64 twin use six concurrent workers to check
limits, exact failure totals, snapshots, arena backing charges and rollback.

ARM64 Linux/Darwin, Windows and WebAssembly return `ARENA_ERR_UNSUPPORTED`
from this API. ARM64 ordered loads/stores do not supply compare-and-swap;
their existence is not evidence of a usable concurrent-budget backend.

`arena_test` drives 400 rounds of "allocate until the budget refuses,
then reset" with a mix of small and oversized requests and checks that
`reserved` never exceeds the budget, returns to one chunk after each
reset, and that resident memory (`/proc/self/statm`) does not creep.

## Bounded diagnostics (`lib/metrics.w`)

Everything is sized at creation; nothing grows with traffic, and there
is no external metrics dependency.

- **Registry**: `metrics_new(capacity)` pre-registers the standard ids
  the design asks for — `METRIC_TASKS_PENDING`, `METRIC_JOBS_QUEUED`,
  `METRIC_BYTES_QUEUED`, `METRIC_WORKERS_BLOCKED`, `METRIC_WORKERS_RUNNING`,
  `METRIC_ALLOC_FAILURES`, `METRIC_FDS_OPEN` — and `metrics_counter` /
  `metrics_gauge` register more up to the fixed capacity (then return
  -1, which `metrics_add`/`metrics_set` ignore). Counters saturate at
  the largest int instead of wrapping. `metrics_snapshot` copies values.
- **Latency histogram** (optional, `metrics_enable_latency`): 32 log2
  buckets (bucket 0: v <= 0; bucket k: 2^(k-1) <= v < 2^k; the last one
  open-ended), plus count/saturating sum/min/max and
  `metrics_histogram_quantile` (bucket upper bound, capped at max). Values
  are microseconds from `metrics_now_us` / `metrics_observe_since`
  (wrap-safe differences; the 32-bit microsecond clock wraps after ~35
  minutes, so only durations are meaningful).
- **Event ring** (optional, `metrics_enable_events(m, n)`): the newest n
  structured events (`seq`, `time_ms`, `kind`, `value`, text). When full
  the oldest is overwritten and `dropped` counts it. Text is copied and
  truncated to 47 bytes into a preallocated area, so callers may pass
  temporaries.
- **Output**: `metrics_write_fd(m, fd)` (like `task_dump_fd`) and
  `metrics_format(m, buf, cap)` (always terminated; returns the full
  length so truncation is detectable).
- **Open descriptors**: `metrics_count_open_fds()` lists `/proc/self/fd`
  through the unsorted `dir_platform_read` (-1 where `/proc` is absent);
  `metrics_sample_open_fds` stores it in `METRIC_FDS_OPEN`.

**Service integration**: import `lib.service_metrics` and call
`metrics_sample_scheduler(m, s)`, `metrics_sample_executor(m, ex)`, and
`metrics_sample_arena(m, a)` or `metrics_sample_budget(m, b)`. These are
allocation-free snapshots. Sample the scheduler, arena and budget on their
owner thread; the executor snapshot takes its lock. Serialize writers to a
shared registry. Use one owner per metric category; arena and shared budget
allocation counters are alternatives, so do not sample both into the same
registry. `METRIC_WORKERS_RUNNING` counts active jobs;
`METRIC_WORKERS_BLOCKED` counts idle workers waiting for work (a running
job's internal syscall/blocking state is opaque). `lib/transport.w` records
per-operation latency and failure events with `transport_set_metrics`.

## Checked byte transport (`lib/transport.w`)

One interface for protocol adapters: read, write, close, deadline and
peer identity. Every operation fills an `io_result` (`lib/io.w`) and
returns its `IO_*` status, so transport failures read exactly like
descriptor failures.

```text
transport_read_some(t, buf, len, &r)   1..len bytes | EOF | TIMED_OUT | CANCELLED | IO_ERROR
transport_read_exact(t, buf, len, &r)  EOF with the partial count when the peer ends early
transport_write_all(t, buf, len, &r)   all bytes, or the confirmed prefix + the failure
transport_close(t, &r)                 once; later calls are IO_OK no-ops
transport_set_deadline / transport_set_timeout(t, ms)   absolute, -1 clears
transport_peer(t), transport_authenticated(t), transport_require_authenticated(t, &r)
transport_free(t)                      closes if needed, frees adapter state + descriptor
```

- **Deadline**: absolute, in `time_monotonic_ms` units, covering every
  wait of every later operation. An operation starting after it passed
  is `IO_TIMED_OUT` without touching the descriptor. The generic layer
  recomputes the remaining time on every retry, so signals and spurious
  wakeups never extend it.
- **Waiting**: through `io_poll` (`lib/io_wait.w`): inside a task only
  the task parks (tested: a reader waiting on one socket does not stop a
  writer task on the same scheduler), elsewhere `poll(2)` blocks the
  thread. The socket adapter uses `MSG_DONTWAIT`, so blocking and
  non-blocking sockets both work and a large write stops at the
  deadline with the confirmed prefix in `transferred`.
- **No SIGPIPE**: writes pass `MSG_NOSIGNAL` (Darwin: `SO_NOSIGPIPE` at
  construction). A closed peer is `IO_IO_ERROR` with `EPIPE` or
  `ECONNRESET`; a peer that finished sending is `IO_EOF`.
- **After close** the descriptor number is never used again (it may have
  been reused): reads and writes are `IO_IO_ERROR`/`EBADF`.
- **Adapters** supply `read_some`, `write_some` (one attempt, a wait of
  at most `timeout_ms`, one more attempt; `IO_WOULD_BLOCK` /
  `IO_INTERRUPTED` ask the generic layer to retry) and `close`.
  Constructors: `transport_from_socket(fd, peer, owns_fd)`,
  `transport_tcp_connect(ip, port, timeout_ms, &r)`,
  `transport_tcp_accept(listen_fd, timeout_ms, &r)`,
  `transport_unix_connect(path, &r)`,
  `transport_unix_accept(listen_fd, path, timeout_ms, &r)`.
- **Identity**: `peer` describes the address the socket was connected to
  or accepted from (`tcp:127.0.0.1:8080`, `unix:/run/app.sock`,
  `unix-client@/run/app.sock`). It is not authenticated, and
  `authenticated` is 0 for every adapter in this file;
  `transport_require_authenticated` returns `IO_UNSUPPORTED` for them so
  a protocol that needs an authenticated peer fails closed.

`transport_tcp_connect` preserves connection errors (including refused
connections), timeout and cancellation through `net_connect_timeout_checked`.
`transport_peer_address` queries the kernel's peer sockaddr, independently
of the display label. `transport_peer_credentials` supplies local Unix OS
credentials; TCP explicitly reports unsupported. `transport_shutdown` supports
read/write/both half-close and preserves the remaining direction. These control
operations honor cancellation/deadlines and do not release the descriptor.
Linux x86/x64/ARM64 and Darwin have adapters; unsupported transports return
`IO_UNSUPPORTED`. Details and ownership contracts:
[socket identity and half-close](socket_identity.md). `MSG_DONTWAIT` values
support Linux and Darwin only. Ready I/O checks the current task's cancellation and
deadline before touching descriptors, using `io_check`; shielded cleanup
honors the scheduler's existing shield behavior.

## Checked TLS transport (`lib/transport_tls.w`)

`transport_tls_connect(fd, server_name, cfg, timeout_ms, &r)` performs a
client handshake on an already connected socket. `server_name` is the DNS
identity to verify, independent of the socket's IP address; `cfg` may be 0
for secure defaults. `transport_tls_accept(fd, peer, server_cfg, timeout_ms,
&r)` performs a server handshake on an accepted socket. Both constructors
own the socket on every path, including failures, return 0 on failure, and
fill the caller's `io_result`. Configurations are borrowed only during the
handshake and may be freed once it returns. After construction the ordinary
transport read/write/deadline/close/peer/metrics APIs apply.

- **Authentication**: a client verifies the trust chain and DNS hostname
  before reporting `authenticated = 1`; its peer string is `tls:hostname`.
  Trust comes from `tls_config.trust_store_path`, then `SSL_CERT_FILE`, then
  distro bundle paths. Unloadable trust stores, wrong names, expired or
  invalid chains fail closed. `insecure_skip_verify` skips chain and name
  verification and ALWAYS yields `authenticated = 0`, even after a valid
  encrypted handshake. Servers default to anonymous clients. Optional or
  required client-certificate authentication validates the client chain and
  key-possession proof before exposing `tls-client-sha256:<fingerprint>` as
  authenticated identity. Configure a separate client trust bundle on the
  server and client credentials on the client. See [mutual TLS](mutual_tls.md)
  for configuration, failure behavior and authorization boundaries.
- **I/O results**: timeout and cancellation are distinct `IO_TIMED_OUT` and
  `IO_CANCELLED`; native socket errors are retained. TLS protocol errors and
  TCP EOF without close_notify are `IO_IO_ERROR` with no synthetic errno.
  A received close_notify is `IO_EOF`. Errors live on each TLS connection;
  `transport_tls_last_error(t)` exposes a static diagnostic surviving close.
  A configuration's compatibility error string cannot overwrite another
  connection's error.
- **Progress and waiting**: reads expose authenticated plaintext only;
  writes confirm each completely sent encrypted record independently, so a
  later failure preserves the plaintext prefix in `r.transferred`. Bytes in
  an incomplete record are excluded. Raw TLS I/O in checked mode uses
  nonblocking syscalls and `io_poll`, both inside and outside tasks, with
  the remaining absolute deadline recomputed on each attempt. Task state
  is checked even on continuously ready descriptors. A timeout/error during
  a TLS record poisons the connection because the record parser is not
  resumable; close and reconnect. A generic transport deadline or task
  check that fails before the adapter runs consumes nothing and does not
  poison the connection. Use one operation at a time per transport.
- **Shutdown**: close_notify is sent within the current deadline (at most
  1000 ms when none was set). Close reports an alert-send error or the
  socket close error, always releases the socket and wipes keys, and is
  idempotent. It does not wait for the peer's close_notify.
- **TLS scope**: TLS 1.3, ChaCha20-Poly1305, X25519; server keys are ECDSA
  P-256. Host verification uses SAN dNSName wildcards, without CN fallback
  or iPAddress SAN support. Trust bundles are read per handshake. Legacy
  `tls_connect`/`tls_read`/`tls_write` retain their existing API; importing
  this adapter opts into checked socket I/O and per-record progress.

`transport_tls_test` and its x64 twin exercise real trusted handshakes,
wrong hostnames and missing trust stores, insecure identity semantics,
nonblocking sockets outside tasks, task suspension/cancellation, ready I/O
with expired/cancelled tasks, partial encrypted writes, abrupt truncation,
clean shutdown and expired close. Common transport tests additionally check
partial counts returned together with an adapter error.

## Deferred

- Native ARM64/Windows shared-budget backends (the explicit concurrent API
  is implemented for Linux x86/x64).
- Native ARM64 Linux and Apple Silicon qualification of atomic ordering and
  durability; adapters and repeatable harnesses are implemented, while native
  hardware evidence remains pending ([qualification](arm64_qualification.md),
  [durability ports](durability_ports.md)).
