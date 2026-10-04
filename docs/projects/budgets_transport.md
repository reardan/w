# Memory budgets, bounded diagnostics and the checked byte transport

Stage W5 of [issue #514](https://github.com/reardan/w/issues/514)
(design copy: `docs/projects/reliable_services.md`): "P1 memory budgets
and diagnostics" and "P2 transport". Three leaf libraries, no compiler
or runtime changes:

| File | What it is |
|---|---|
| `lib/arena.w` | budgeted chunk arena + shared `mem_budget` |
| `lib/metrics.w` | fixed-size counters/gauges, log2 latency histogram, bounded event ring |
| `lib/transport.w` | checked byte-transport interface + TCP/Unix socket adapter |

Tests: `lib/arena_test.w`, `lib/metrics_test.w`, `lib/transport_test.w`
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
- **Single owner.** Neither arenas nor budgets lock. Use one per worker
  thread (tasks on one scheduler are cooperative, so they can share
  one), or guard with a `wmutex`. A lock-free shared budget would need
  `atomic_cas`, which is host x86/x64 only today, so it is deferred
  rather than making the file arch-specific.

`arena_test` drives 400 rounds of "allocate until the budget refuses,
then reset" with a mix of small and oversized requests and checks that
`reserved` never exceeds the budget, returns to one chunk after each
reset, and that resident memory (`/proc/self/statm`) does not creep.

## Bounded diagnostics (`lib/metrics.w`)

Everything is sized at creation; nothing grows with traffic, and there
is no external metrics dependency.

- **Registry**: `metrics_new(capacity)` pre-registers the standard ids
  the design asks for — `METRIC_TASKS_PENDING`, `METRIC_JOBS_QUEUED`,
  `METRIC_BYTES_QUEUED`, `METRIC_WORKERS_BLOCKED`,
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

**Integration points** (not wired, to stay out of files owned by other
stages): `task_dump_fd` (`lib/task.w`) already reads
`s.active_count` and `s.ready.length`; a sampler setting
`METRIC_TASKS_PENDING` from them is a three-line addition there. The W3
bounded executor owns the queued-jobs/bytes and blocked-worker numbers.
Arena and `mem_budget` failure counters feed `METRIC_ALLOC_FAILURES`.
`lib/transport.w` already records per-operation latency and failure
events when given a `metrics` (`transport_set_metrics`).

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

Known limits: `transport_tcp_connect` goes through `net_connect_timeout`,
which does not preserve the connect errno (a refused connection is
`IO_IO_ERROR` with `native_error` 0) — fixing it needs a
`getsockopt(SO_ERROR)` syscall wrapper, which `lib/` does not have yet;
the same gap (no `getpeername`, no `SO_PEERCRED`) is why peer strings
come from the connect/accept address and Unix clients carry no
credentials. There is no half-close (`shutdown(2)` is not wrapped). The
`MSG_DONTWAIT` value is chosen for Linux and Darwin only.

## TLS audit (`libs/standard/net/tls.w`, `x509.w`)

Read for this stage; nothing in it is wired into `lib/transport.w`, and
no adapter is advertised as authenticated or mutual TLS.

- **Client certificates / mutual TLS: not implemented.** The client
  never handles a `CertificateRequest`: a server that sends one breaks
  the handshake ("expected Certificate"). The server role (`tls_accept`)
  never sends `CertificateRequest`, so it cannot authenticate clients. A
  server-side TLS transport therefore must keep `authenticated = 0`; a
  client-side one could claim only *server* authentication, and only
  when verification was not skipped.
- **Trust configuration**: `tls_config.trust_store_path`, else
  `SSL_CERT_FILE`, else the distro bundle paths; an unloadable store
  fails the handshake (closed). The bundle file is re-read and re-parsed
  on every handshake (cost, and a mid-flight file swap changes trust),
  and there is no in-memory anchor or pinning option through
  `tls_config`. `insecure_skip_verify` skips chain *and* hostname checks
  (CertificateVerify and Finished are still checked); an adapter must
  report `authenticated = 0` whenever it is set. TLS 1.3 only, one
  cipher suite (ChaCha20-Poly1305), X25519; the server takes ECDSA P-256
  keys only.
- **Hostname verification**: SAN dNSName only (RFC 6125 wildcards, no CN
  fallback); IPv4 literals never match and there is no iPAddress SAN
  support, so connecting by IP cannot verify. **Fixed:** a null or empty
  hostname no longer skips the check silently: `x509_verify_chain` fails
  closed ("x509: no hostname to verify"), and chain-only callers must use
  the explicit `x509_verify_chain_no_hostname`. A null or empty
  `server_name` no longer faults in the ClientHello builder: `tls_connect`
  fails before any I/O ("tls: no server name to verify") unless
  `insecure_skip_verify` is set, in which case the ClientHello omits SNI.
  An adapter that wants an authenticated peer must still pass a non-empty
  server name.
- **Nonblocking progress**: record I/O loops until a whole record moves.
  On `EAGAIN` it calls `io_wait`: inside a task the task parks (bounded
  by `io_timeout_ms`); outside a task `io_wait` fails at once, so a
  non-blocking socket outside a task fails mid-record. There is no
  resumable state: any timeout or error mid-record leaves the connection
  unusable. `tls_read` returns only `>0`, `0` (close_notify) or `-1`,
  and `tls_write` is all-or-nothing `-1`; timeouts are indistinguishable
  from errors and the reason is a static string on the shared
  `tls_config` (not per connection). An adapter would map `-1` to
  `IO_IO_ERROR` with no errno.
- **Shutdown**: `tls_close` sends close_notify best effort and frees the
  connection, wiping keys; it does not close the socket (caller owns it)
  and does not wait for the peer's close_notify. A received close_notify
  is clean EOF; a TCP EOF without one is an error (truncation is
  detected). No half-close.

Before a TLS adapter is exposed: map results to `IO_*` with a timeout
distinct from failure, keep per-connection error state, require a server
name, reflect `insecure_skip_verify` in `authenticated`, and decide
whether non-blocking use outside tasks is supported. Mutual TLS needs
`CertificateRequest` + client `Certificate`/`CertificateVerify` on both
roles and its own tests before anything may be called mTLS.

## Deferred

- Thread-safe shared `mem_budget` (needs portable atomics).
- `getsockopt(SO_ERROR)`, `getpeername`, `SO_PEERCRED`, `shutdown`
  wrappers in the syscall layer (errno-preserving connect, kernel-sourced
  peer identity, Unix peer credentials, half-close).
- Task-scheduler sampler for `METRIC_TASKS_PENDING` in `lib/task.w`;
  executor gauges from W3.
- TLS transport adapter (client side, server-authenticated only) after
  the audit items above.
