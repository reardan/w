# Index daemon: `windexd`

Status: **implemented** — `tools/index/w_indexd.w` (built as `bin/windexd`,
`./wbuild windexd`), sharing the query engine in `tools/index/w_index_core.w`
with the CLI (`tools/index/w_index.w`, `./wbuild windex` → `bin/windex`).
See `docs/projects/semantic_index.md` for the query semantics this daemon
serves (find-references, callers/callees, struct fields, etc.) — this doc
only covers the caching/serving layer on top.

## Why this exists

Every `windex`/`w-index-mcp` query shells out to `wv2 symbols --json
<entry files>` to get a declaration set (`tools/index/w_index.w`'s
`windex_build`), and that compile is the dominant cost by a wide margin —
`wimcp` is a long-lived stdio process per editor/agent session, but it
still re-ran this compile from scratch on *every single call*, including
identical repeat queries against the same files. Measured before this
change:

| Query | Cold (no cache) |
|---|---|
| `references` on a single-file entry (`tools/mcp/w_index_mcp.w`) | 1.85–1.89s, unchanged across 3 identical repeat calls |
| `references` on `w.w` (whole-compiler entry) | 17.1s |
| equivalent `grep -rnw` | 6–7ms |

The JSON-RPC/stdio protocol itself is not the bottleneck — spawn +
handshake + teardown measured at under 1ms. 100% of the above is the
`wv2 symbols --json` recompile. See issue #113 for a further breakdown of
*why* that compile itself is slow (unbuffered single-byte
`read`/`write` syscalls in `getchar()`/`putc()`, `lib/lib.w`) — a
complementary, lower-level fix that would shrink both the cold path and
every cache-miss rebuild here, independent of this daemon.

## Shape

`windexd` is a persistent process, decoupled from any one client's
connection lifetime (unlike `wimcp`, which lives and dies with one editor
session): it keeps compiled `windex_index` results warm in memory across
however many queries and however many separate CLI/MCP client processes
ask for them, until the daemon itself is stopped or the container is
recycled.

- **Transport**: JSON-RPC 2.0 (`lib.json_rpc`) over a TCP socket bound to
  `127.0.0.1` on an OS-assigned ephemeral port (`lib.net`,
  `socket_bind_ipv4(fd, ip, 0)`), served via `lib.event_loop` +
  `jsonrpc_serve_listener` — the same listener/event-loop machinery
  `lib/json_rpc_test.w` already exercises, reused as-is rather than
  rebuilt. Loopback TCP was chosen over a Unix domain socket because
  `lib.net` has IPv4 TCP/UDP support today and no `sockaddr_un`/path-socket
  primitives; adding those was out of scope here (tracked as a possible
  follow-up, not needed for correctness or security on a single-user
  dev container).
- **Discovery**: the daemon writes its port to `bin/.windexd.port`
  (`windexd_port_file()`/`windexd_read_port()`/`windexd_write_port()` in
  `w_index_core.w`, shared so the CLI and daemon cannot disagree on the
  format). Clients read that file and connect; a missing file, refused
  connection, or malformed response are all treated identically as "no
  daemon" — see Fallback below.
- **Protocol**: one method, `windex_query`, params
  `{subcommand, name, files}` (the same shape as a `windex <subcommand>
  <name> <file...>` CLI call), result `{"stdout": "<ndjson>"}` — the
  same NDJSON text the CLI would have printed, so a client cannot tell
  the difference except by latency. A `shutdown` method (`jsonrpc_stop`)
  exists for clean teardown in tests and manual operation; it is not
  called by normal CLI/MCP traffic.
- **Query engine**: `tools/index/w_index_core.w` is the refactor that
  makes this possible — the original `w_index.w` held the built index
  and scan caches in module globals (fine for a one-shot CLI process,
  wrong for a server that must hold several independent indexes at
  once). Every function now takes an explicit `windex_index*` and an
  output `string_builder*` instead of touching globals or fd 1 directly.
  The CLI (`w_index.w`) is now a thin wrapper: parse argv, try the
  daemon, otherwise call `windex_build` + `windex_dispatch` locally and
  print the buffer — byte-for-byte the same output as before this
  change (`index_test.w`, which drives `bin/windex` as a black box,
  needed no changes).

## Cache

Keyed by the requested entry files (sorted, joined with a `\x1f`
separator — order-independent, so `windex references x a.w b.w` and
`windex references x b.w a.w` share a cache entry). One `windex_index`
per key, unbounded — no eviction. Every declaration's *file* becomes
part of that entry's tracked transitive closure
(`windex_index.files`, populated by `windex_build` from every declared
file).

**Freshness**: content-hashed, not mtime-based (this codebase has no
`stat()`/mtime syscall wrapper — `tools/wexec.w`'s build cache made the
same choice for the same reason). On every request, every file in the
cached entry's transitive closure is re-read and rehashed
(`windex_hash_file`, the same two-multiplier rolling hash
`tools/wexec.w`'s `wexec_hash` uses, reimplemented in `w_index_core.w`
rather than imported since `wexec.w` owns its own `main()` and this
codebase's import model has no story for importing a file that defines
one — see "No library imports across CLI mains" below). Any mismatch —
content changed, or a previously-present file is now missing — triggers
a full rebuild of that one entry; other cached entries are untouched.

**Per-file scan cache** (`windex_file_cache`/`windex_file_identifiers`
in `w_index_core.w`): a cache-hit index rebuild is not the whole story —
`windex_cmd_references`/`callers`/`callees` still re-read and
re-scanned every file in the closure for identifiers on *every* query,
even repeat queries against the same unchanged files, since only the
`wv2 symbols --json` compile was cached. `windex_file_identifiers`
closes that gap: a process-wide (not per-`windex_index`), content-hash
keyed cache of `windex_scan_all_identifiers`'s output per file, shared
across every cache entry — the same file appearing in more than one
entry's transitive closure, or being queried by name after name, now
gets scanned once. Content-addressed like the index cache: a hash
mismatch just replaces the entry, no separate invalidation step. The
returned list is shared, so callers that mutate a hit in place
(`references`/`callers` add `file`/`is_declaration` fields) clone first
via `windex_clone_identifier_hit`/`windex_filter_identifiers`; `callees`
only reads, so it uses the shared list directly.

| Query (`references sym_get_value w.w`, 61 hits) | Time |
|---|---|
| Cold (daemon builds it) | 23.9s |
| Warm, index cache only (pre-scan-cache) | 2.15s |
| Warm, index + scan cache | 0.10s |

vs. the common case of a single-file entry point:

| Query (`references imcp_run_cmd tools/mcp/w_index_mcp.w`, 6 hits) | Time |
|---|---|
| Cold | 1.87s |
| Warm | 0.09s |

A different symbol name queried against the same already-cached `w.w`
entry (`callers windex_build w.w`, a cold *index* hit but a warm *scan*
hit) also lands at 0.09s, confirming the scan cache pays off across
different queries against the same files, not just identical repeats.
All warm results are byte-identical to the cold ones.

## Fallback and auto-start

The CLI (`windex_run` in `w_index.w`) tries the daemon first
(`windexd_try_query`) for every subcommand except the stateless
`imports`. On *any* failure — no port file, connection refused,
malformed response — it silently falls back to building the index
in-process exactly as before this change, so `windex`/`wimcp` never
require the daemon to function correctly, only to be fast.

Before falling back, the CLI fires off `bin/windexd` detached
(`windexd_spawn_detached`: `process_spawn` with all three stdio streams
set to `process_null()`, not waited on) so a *later* call — in this
process, in a different terminal, from a different MCP client session —
finds a warm daemon. This is what makes "always have the index server up
and running" true in practice without any setup step: the first query
anywhere in a container's lifetime pays the cold-path cost and warms the
daemon; every query after that, from any client, is warm.

`bin/wimcp` (`w-index-mcp`) needed **no changes** for this — it already
shells out to `./bin/windex` per call, so it inherits the daemon
transparently through the CLI.

## Known limitations (honest MVP tradeoffs, not hidden ones)

- **No Unix domain socket.** Loopback TCP on an OS-assigned port is
  visible to any process that can read `bin/.windexd.port` and connect
  to localhost — fine for a single-user dev container, not a sandboxing
  boundary. A future `lib.net` addition of `sockaddr_un` would let this
  move to a filesystem-permissioned socket instead.
- **No `unlink()` in this codebase's syscall surface**, which shaped two
  design choices: (1) cache freshness is content-hash based rather than
  mtime-based (see above), and (2) the CLI's duplicate-spawn guard
  (`windexd_spawn_lock_holder_alive` in `w_index.w`) tracks the last
  spawned daemon's pid and tests liveness with `kill(pid, 0)` rather than
  using an exclusive-create lock file it could later remove. This closes
  most of the spawn race (many CLI calls racing to spawn before any
  daemon has bound a port) but not all of it — two daemons can still both
  pass the liveness check within the same instant. Observed in practice
  during test runs: a small number of harmless orphaned `windexd`
  processes, each idle in `event_loop_run()`, never discovered by any
  client because only the last one to write `bin/.windexd.port` is
  reachable. They cost idle memory, not correctness, and exit when the
  container is recycled. A true exclusive lock (`open(..., O_CREAT |
  O_EXCL, ...)`) would need a matching `unlink()` to be reusable after
  the lock holder exits; adding that syscall wrapper (per architecture,
  `lib/__arch__/*/syscalls.w`) was out of scope here.
- **Unbounded cache, no eviction.** A dev session touching many distinct
  entry-file sets grows `windexd_cache`/`windexd_file_hashes` without
  bound. Not a problem at the scale this has been used at; an LRU cap
  would be a small, self-contained follow-up if it ever is.
- **Single-threaded, one request at a time.** `windexd` is a single
  process running one `event_loop`; a cache-miss rebuild (a blocking
  `process_run` of `wv2 symbols --json`) blocks the whole daemon,
  including unrelated queries against already-cached entries, for the
  duration of that compile. Matches the CLI's own blocking behavior
  today (no regression), but means a cold query against `w.w` briefly
  stalls every other client. Not addressed here; would need either a
  worker-process pool or making `windex_build`'s subprocess call
  non-blocking against the event loop.
- **No library imports across CLI-`main()` files.** This codebase's
  import model has no precedent for one file with a `main()` importing
  another file that also defines one (confirmed by grep — no existing
  `.w` file does this). `w_index_core.w` (`main()`-free, imported by
  both `w_index.w` and `w_indexd.w`) is where the content-hash helper
  (`windex_hash_text`/`windex_hash_file`) lives, so the daemon and the
  per-file scan cache share one implementation — but it is still a
  second copy of the same rolling hash `tools/wexec.w`'s `wexec_hash`
  uses, since `wexec.w` is itself a `main()`-bearing CLI and can't be
  imported. If this pattern recurs elsewhere, factoring `wexec_hash`
  into a `main()`-free `lib.hash`-style module would remove the last
  duplication for good.
- **`callers`/`callees` are still O(references × declarations)** per
  query (`windex_enclosing_function` in `w_index_core.w` does a linear
  scan of every declaration per reference). The scan cache above removes
  the *scanning* cost from a hot loop over the same files; this
  resolution cost is untouched and would now be the next bottleneck a
  repeated `callers`/`callees` hot loop would hit, per
  `docs/projects/semantic_index.md`'s existing note on this.

## Testing

`tools/index/indexd_test.w` (`./wbuild indexd_test`) spawns a real
`bin/windexd`, talks JSON-RPC to it directly over its advertised port
(not through the CLI, so failures point at the daemon rather than at
`w_index.w`'s fallback logic), and asserts:

- **Correctness**: `symbol`/`callers` results against the existing
  `tests/index_fixture.w` match what `index_test.w` already expects from
  the CLI path — the daemon must return identical answers to a direct
  build, not just *some* answer.
- **Cache-hit correctness**: an unchanged repeat query against the same
  entry file returns the same result (not empty, not stale-but-wrong).
- **Index-cache invalidation**: a scratch fixture (generated at test
  time, not a tracked file — mutating a real `tests/` fixture mid-test
  would be poor practice) is queried via `symbol`, rewritten to rename
  its one symbol, then queried again with the *same* entry-files cache
  key; the daemon must stop finding the old name and start finding the
  new one, proving the freshness check actually rebuilds rather than
  serving a stale cached index.
- **Scan-cache invalidation**: a separate scenario, since `symbol`
  never touches `windex_file_identifiers` (only `references`/
  `callers`/`callees` do). Queries `references` for a target function,
  confirms a repeat query returns the same count (cache hit), then adds
  a second call site to the same file and confirms the new occurrence
  is visible on the next query — the scan cache must not serve a stale
  hit count.

`index_test.w` and `index_mcp_test.w` needed no changes and still pass —
both exercise `bin/windex`/`bin/wimcp` as black boxes and get
byte-identical output whether or not a daemon happens to be warm during
the run (verified: a daemon incidentally spawned by one test's fallback
path was observed serving a *later* test's queries during a real
`./wbuild` run, with no assertion changes needed).
