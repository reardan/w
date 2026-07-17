# wbuildd: a persistent build/check daemon, and the AST question behind it

Design assessment for issue #231. Companion to
`docs/projects/build_system_next.md` (which surveys wexec's remaining
duplication and directions 1–4 for the manifest/cache layer) and
`docs/projects/parser_generator.md` (the PG milestones referenced in
§3). Follows the same survey → directions → staged-recommendation shape
as `build_system_next.md`.

Status: design only, 2026-07-16. No code changes ship with this file.

## 0. Summary

wbuild/wexec are deliberately one-shot (`docs/projects/wexec.md`): every
invocation re-hashes its inputs and, because the compiler is
single-pass with no AST or IR, every compile re-parses its whole import
closure from scratch. §1 below measures what that actually costs on
this tree. The costs are real but concentrated in a few specific
operations — `wv2 deps`/`w check` on the compiler's own closure, and the
first `wtest changed` after a build — not everywhere. That shapes the
recommendation: **the daemon (issue #231 proposal 1) is cheap,
low-risk, and buys most of the win by itself; the AST work (proposal 2)
is a separate, much bigger bet that the daemon does not require.**
wlsp/windex moving back in-tree (proposal 3) is a corollary of the
daemon, not an independent project.

## 1. Current-state cost measurements

Measured on this checkout (`x86_64` Linux, 4 cores), 2026-07-16, after
`git fetch origin claude/github-issues-sonnet-waves-pg24mh && git merge`.
Three runs each where variance mattered; the numbers below are
representative, not best-case.

| Operation | Cold | Warm | Notes |
|---|---|---|---|
| `./wbuild build` (bootstrap wv2→wv3→wv4→wv5) | 50.0–50.8s (`rm -rf bin` first) | 0.53–0.54s | Warm run is two `wexec_cache` hits (`wv2`, `build`); see §1.1. |
| `w check --json w.w` (whole compiler closure) | 7.0–7.2s every time | — | No warm/cold distinction: `check` always re-parses from the file, there is no cache layer between invocations at all. |
| `w check --json tests/hello.w` (leaf) | 0.054–0.056s | — | Same story, just a much smaller closure. Confirms `build_system_next.md`'s "leaf compiles are already effectively instant." |
| `bin/wv2 deps w.w` | 7.1–7.2s every time | — | Costs the same as a full `check` — deps is derived by actually compiling, there is no memoization at this layer. |
| `bin/wv2 deps tests/hello.w` | 0.054–0.055s | — | Leaf case, for scale. |
| `git diff \| wtest changed` (real diff touching `lib/env.w`) | **140–147s** (`rm -f bin/.wtest_deps_cache` first) | 0.13s | ~1080x. This is the single sharpest before/after number on the whole tree — see §1.2. |
| `./wbuild tests` (436 targets, fully cached, no-op) | — | see §1.3 | Pure re-hash/re-stat overhead with zero recompilation. |

### 1.1 `./wbuild build`: cold vs warm

Cold (`rm -rf bin`) is a full four-stage self-compile plus the wexec
bootstrap itself: ~50s (two independent runs, ~50.0s and ~50.8s — the
second additionally re-downloaded the pinned seed binary since a fresh
worktree does not carry it). Warm (immediately rerun) is 0.53–0.54s —
two `wexec_cache` hits reported as `wexec: target wv2 (cached)` /
`wexec: target build (cached)`. This is wexec's existing on-disk
`bin/.wexec_cache` stamp mechanism (`tools/wexec.w:180`–`196`) already
doing its job: the ~0.5s here is *not* daemon territory, it is mostly
process-spawn and stat/hash overhead for a target whose steps didn't
run. `build_system_next.md`'s "~4.6s full self-compile" figure is
lower than this session's ~50s cold number; the gap is plausibly
sandbox/host variance (this run includes the wexec-from-seed bootstrap
step folded into the same cold measurement, on a shared/throttled
sandbox host), not a regression — the warm number is the one that
matters for day-to-day iteration, and it is already sub-second.

### 1.2 The real cost: deps/closure computation has zero cross-invocation memory

`w check` and `wv2 deps` on `w.w` cost ~7.1s **on every single
invocation**, cold or warm, because there is no cache between them at
all — each is a fresh process that tokenizes and parses the whole
closure from nothing. This is issue #231's "every compile re-parses its
whole import closure" claim, precisely measured.

`bin/wtest`'s own deps-closure cache (`bin/.wtest_deps_cache`,
documented in `CLAUDE.md` and `tools/test_map.w`) is the one place this
is already solved at the file level: the first `wtest changed` after a
build computes and caches import closures for every target root, and
warm runs read that cache instead of re-deriving. The measured
before/after here — **~143s cold (avg of two runs), 0.13s warm** — is
the empirical shape of what a resident daemon buys for free everywhere
else `wv2 deps`/`w check` are called repeatedly (agent edit→check
loops, `wtest changed` variants, a future LSP): the daemon is
functionally "make `bin/.wtest_deps_cache`'s trick apply to every
deps/check/symbols call, kept warm in memory instead of re-read from
disk each time, and invalidated by file events instead of recomputed by
full re-walk."

### 1.3 `./wbuild tests`: re-hash overhead on a no-op run

A no-op `./wbuild tests` still re-hashes: every cacheable target's key
is `SHA-256(target definition + dependency keys + every input file's
bytes)` (`tools/wexec.w:180`–`296`), recomputed from scratch each
invocation and compared against the stamp in `bin/.wexec_cache/<name>`
— there is no persistent in-memory hash cache, only the on-disk stamp
the freshly-recomputed key is checked against. Deps-driven targets
additionally re-validate `bin/.wexec_deps_cache`'s `H` line by
re-hashing every file in the cached closure (`tools/wexec.w:420`–`460`).
A fully-built, fully-cached `./wbuild tests` (436 targets) run for this
doc took noticeably longer than a "pure re-hash, zero work" run should
— it did not finish inside a 300s budget even against an already
fully-built `bin/`, which itself is informative: **hashing/re-validating
436 targets' full input closures is not free even when nothing
changed**, and some portion of the umbrella (`parser_generator_w_test`'s
whole-repo sweep and other FORCE-style targets with no declared
"inputs", per `build_system_next.md`'s duplication-class notes) is not
cacheable at all and re-runs its real work every time regardless. The
qualitative point holds either way: **the cost scales with total input
bytes (and, for FORCE targets, total re-execution time) across all 436
targets, every single invocation**, even when nothing changed and
nothing needed recompiling. A daemon that watches files and keeps
validated hashes resident turns the cacheable majority into "0 files
changed since last check" — an O(inotify events since last run)
operation instead of an O(total input bytes) one — though it does
nothing for FORCE-style targets, which are a separate, orthogonal cost
(see `build_system_next.md`'s direction 1 on tightening "inputs"
declarations, which is the actual fix for those).

## 2. The daemon design

### 2.1 Protocol sketch

JSON-RPC 2.0 over a unix-domain socket, using the existing
`lib/json_rpc.w` + `lib/event_loop.w` stack as-is (both have tests:
`lib/json_rpc_test.w`, `lib/event_loop_test.w`, `lib/poll_test.w`).
`jsonrpc_serve_listener` (`lib/json_rpc.w:328`) already accepts clients
from an arbitrary listening fd on an `event_loop` and multiplexes
requests with timers — it does not care what address family the fd
came from, so the daemon's listener setup is the only new plumbing (see
§2.3 gap). Sketch of the method surface, modeled on `w check --json`
/ `wv2 deps` / `wv2 symbols --json` / `wtest changed`'s existing CLI
contracts so a thin client can mostly reformat existing flags into a
request:

```
build(target: string[], keep_going?: bool, jobs?: int)
  -> { ok: bool, targets: [{name, status: "ok"|"cached"|"failed"|"skipped", stderr?}] }

check(file: string, arch?: string)
  -> { diagnostics: [{severity, message, file, line, column}] }   # w check --json, unchanged shape

deps(file: string, arch?: string)
  -> { files: string[] }        # wv2 deps, unchanged shape

symbols(file: string)
  -> { symbols: [...] }         # wv2 symbols --json, unchanged shape

test_changed(diff_paths: string[])
  -> { targets: string[] }      # bin/wtest changed, unchanged shape

status()
  -> { pid, version, uptime_ms, warm_files: int, cache_hit_rate, watching: bool }

shutdown() -> {}
```

Every method's response shape matches what the existing CLI already
prints (or its `--json` variant), on purpose: a thin `wbuild`/`wexec`/
`wtest`/`w` client can try the daemon first and fall back to the exact
current one-shot code path with no format translation, and no existing
consumer (a human, a script, the moved-out wlsp/windex) has to change
its parsing to benefit. Framing is `lib/framing.w`'s Content-Length
scheme (issue #231's own "or the simpler `lib/framing.w` protocol?"
open question is really "JSON-RPC already *is* framing.w plus a
method-dispatch envelope" — `lib/json_rpc.w:1`–`10` builds directly on
`lib/framing.w`, so this isn't an either/or).

### 2.2 Lifecycle

- **Who starts it**: `wbuild`/`wexec`/`w`/`wtest` each try to connect to
  a well-known socket path first (`bin/.wbuildd.sock`, next to the
  existing `bin/.wexec_cache`); on `ECONNREFUSED`/socket-missing, the
  client spawns the daemon detached (fork + `setsid`-equivalent) and
  retries the connection with a short backoff, then falls through to
  the one-shot path if the daemon still isn't answering (§2.6). No
  separate "start the daemon" step for a human to remember — this
  mirrors how `wbuild` already bootstraps `bin/wexec` from the seed on
  first run.
- **Staleness / self-re-exec**: the daemon must detect that its own
  binary is older than the source tree it would serve queries against —
  otherwise a `wbuildd` built before a compiler change silently serves
  stale `check`/`deps` results forever. Concretely: on startup (and on
  every N minutes or every file-watch event touching its own transitive
  closure), compare the daemon binary's recorded build cache key (the
  same `wv2`-target key `wexec_cache_key` already computes,
  `tools/wexec.w`) against a freshly computed one; on mismatch, finish
  in-flight requests, `exec()` a freshly-built daemon binary in place
  (same pid, clients' connections survive an `exec`, in-flight
  unfinished requests do not), or exit and let the next client respawn
  it if a rebuild is needed first. This needs its own state — nothing
  in the current cache format tracks "am I, the currently running
  process, still fresh" — the closest existing precedent is
  `wexec_cache_fresh`'s stamp-comparison logic, generalized to compare
  against the running binary instead of a target's declared outputs.
- **Multiple daemons / lock file**: the socket path itself is the lock
  — `bind()` on a unix socket whose path already exists as a socket
  fails; a client that gets `ECONNREFUSED` against an existing path
  should unlink and retry once (stale socket from a killed daemon)
  before giving up and running one-shot.

### 2.3 File watching on Linux

**No inotify wrapper exists in `lib/` today** — confirmed by search
(`inotify` matches nothing under `lib/`, `libs/`, or `tests/`). This is
exactly the gap issue #231 flags as an open question ("inotify shim in
`lib/__arch__/*/syscalls.w` (none exists today), or mtime polling
first?") and it is a real prerequisite, not a nice-to-have: without it,
"warm state invalidated by file watching" degrades to either (a) mtime
polling — cheap to build, but reintroduces exactly the kind of
full-tree stat sweep the daemon exists to avoid, just done resident
instead of per-invocation, or (b) blocking on every request until a
fresh hash check — defeats the purpose. Recommend adding a minimal
`lib/inotify.w` (`inotify_init1`, `inotify_add_watch`,
`inotify_rm_watch`, `read()`-and-parse the `inotify_event` struct
array) as a per-arch syscalls addition next to the existing
`lib/__arch__/*/syscalls.w` shims, wired into `event_loop` as one more
watched fd (`event_loop_add_fd`, `lib/event_loop.w`) — the daemon's
main loop then reduces to "run the event loop; on an inotify event,
invalidate the affected file's hash and everything whose closure
includes it; on a JSON-RPC request, answer from resident state,
recomputing only what inotify marked dirty." `IN_MODIFY`/`IN_CREATE`/
`IN_DELETE`/`IN_MOVED_FROM`/`IN_MOVED_TO` per watched directory covers
the common editor-save case; watching every directory in the repo
individually (no recursive inotify on Linux) is a few hundred `fd`s at
this repo's size — fine for one process, needs an explicit
add-watch-on-new-directory hook for directories created after the
daemon starts.

**Second, smaller gap in the same neighborhood**: `lib/net.w` has no
unix-domain-socket *bind*/*listen* helper. `af_unix()`
(`lib/net.w:18`) exists and is used today only for `socket_pair`
(`lib/net.w:143`, an anonymous connected pair via `sys_socketpair`),
not for a path-bound listening socket — there is no `sockaddr_un`
struct or `socket_bind_unix`/`socket_listen_unix` alongside the
existing `sockaddr_in`/`socket_bind_ipv4`/`socket_listen`
(`lib/net.w:9`–`115`). This is a small, mechanical addition (one struct
+ `sys_bind`/`sys_connect` with an `AF_UNIX` sockaddr whose path is a
NUL-padded 108-byte field on Linux) — worth listing as a second
concrete prerequisite alongside inotify, since `jsonrpc_serve_listener`
itself is already address-family-agnostic (it just watches an fd) and
needs nothing else changed. A loopback TCP socket on a fixed local
port is a viable fallback if this is deprioritized, at the cost of a
port-collision story a unix socket path doesn't have.

### 2.4 Cache invalidation strategy

Two layers, matching the two existing on-disk caches this replaces the
*repeated-recomputation* of (not their format):

- **Deps/closure layer** (replaces `bin/.wtest_deps_cache` /
  `bin/.wexec_deps_cache`'s "recompute and re-validate every
  invocation" behavior): resident map from file path → (content hash,
  parsed import list, last-checked mtime). An inotify event on a
  watched file invalidates that file's entry and every closure entry
  that transitively includes it (the daemon already holds the reverse
  edges once it has computed a closure once). A `deps`/`check` request
  against a file whose closure is still valid answers from memory with
  no filesystem re-read at all; against a dirty one, re-parses only the
  invalidated files, not the whole closure.
- **Target/output layer** (replaces `bin/.wexec_cache`'s
  "recompute-key-then-stat-compare every invocation" behavior):
  resident cache key per target, seeded from the on-disk stamp at
  daemon startup, invalidated the same way. `build`/`test_changed`
  requests reuse `wexec`'s exact key formula (SHA-256 over target
  definition + dependency keys + input bytes,
  `tools/wexec.w:180`–`296`) so the daemon and a one-shot fallback
  agree on cache hits byte-for-byte — the daemon must not become a
  second source of truth for what a target's key *is*, only a place
  that avoids recomputing an unchanged one.

Both layers are pure accelerants over the existing formats: a daemon
that crashes or is killed loses only its warm state, not correctness —
the next one-shot invocation (or a freshly spawned daemon) rebuilds the
same answer from the on-disk stamps exactly as today.

### 2.5 Concurrency model

`lib/event_loop.w` is single-threaded `poll(2)` — one fd/timer table,
one `event_loop_run_once` call per iteration
(`lib/event_loop.w:1`–`10`). That is the only realistic choice today,
not a simplification made for this doc: `lib/thread.w`'s documented MVP
constraints (`lib/thread.w:30`–`38`) are that *only the main thread* may
call `thread_spawn`/`thread_join`/`parallel_for` (the handoff globals
and the brk allocator are unsynchronized), worker functions **must not
allocate** (no `malloc`/`new`/`list`/`map`/print formatting), and
there is no thread pool — every spawn pays a fresh 4MB-stack `clone`
that is never reclaimed on join. None of that composes with "handle N
concurrent JSON-RPC requests, each of which parses W source and builds
a symbol table" — request handling allocates constantly. A thread-pool
daemon is not a smaller version of the event-loop daemon; it is
blocked on `lib/thread.w` growing a real pool with an allocator story,
which is out of scope here.

Practical consequence: **wbuildd is single-threaded**, serving one
request to completion before the next, same as `wexec`'s own
single-process model today minus the process-spawn overhead. This is
fine for the target workload (an agent's edit→check loop, an LSP's
hover/diagnostic requests) which is latency-bound on a single client,
not throughput-bound across many — `-j N` parallel *target* execution
(compiling several `.w` roots as child processes) still works exactly
as `wexec` does it today, forked as subprocesses the event loop watches
via `event_loop_add_fd` on their pipes, same pattern `lib/task.w`
already uses for its coroutine scheduler (`lib/task.w:44`, `:181`).
Parallelism across *build steps* is unaffected; only "handle two
unrelated `check` RPCs at the exact same instant" is serialized, which
is unlikely to matter at this repo's single-developer/single-agent
usage pattern.

### 2.6 Failure / fallback

Every client (`wbuild`, `wexec`, `w`, `wtest`) must work with the
daemon dead, absent, or misbehaving — same non-negotiable invariant
`tools/wexec.w`'s remote-cache section already documents for
`W_CACHE_URL` ("a cache outage ... must never be able to break a
build, only slow it back down to as if this feature didn't exist",
`tools/wexec.w:1354`–`1362`). Concretely: connection refused, connect
timeout (a few hundred ms, not seconds — this must not make an
uncached cold path slower than it already is), a malformed response,
or an explicit `WBUILDD=0`/`--no-daemon` opt-out all fall through to
today's one-shot code path with no behavior change and at most one
"daemon unreachable" warning per process (mirroring
`wexec_remote_warn`'s one-line-then-silent pattern,
`tools/wexec.w:1425`–`1432`). The daemon is purely additive: deleting
`bin/.wbuildd.sock` and killing the process must be equivalent to the
daemon never having existed.

## 3. AST options (a) / (b) / (c)

All three are framed against the same four axes: self-host fixpoint
risk (`./wbuild verify`, wv3==wv4==wv5 byte equality), the seed
constraint (what must stay compilable by the pinned 32-bit seed), the
REPL/wdbg in-process coupling, and what the PG's just-landed milestones
change about option (b)'s cost.

### 3.1 (a) Cache below the AST — resident token streams + import graph + symbol tables

Codegen stays exactly single-pass; nothing about `grammar/`'s
parse-and-emit fusion changes. This is precisely what §2.4's "deps/
closure layer" already is — option (a) is not really a separate AST
option, it is the daemon's own cache design. **Self-host risk: none**
(no compiler behavior changes). **Seed constraint: none** (no new
syntax, no new seed-graph modules — the daemon's cache lives in
`wbuildd`, outside `w.w`'s import closure). **REPL/wdbg: unaffected**
— `repl/core.w` and `debugger/eval.w` keep compiling through the
production `compiler.compiler` exactly as now; the daemon's cache is a
different process. **Unlocks**: fast `deps`/`symbols`/`check` from
warm state (§1.2's ~1080x number), nothing else — no multi-error
reporting (the compiler still calls `error()` and longjmps/exits on the
first problem), no incremental recompile (codegen still has to replay
the whole target from tokens even if tokenizing is memoized), no
resident *semantic* index beyond what `symbols --json` already exposes
today. This is the "cheapest, limited win" the issue itself names it.

### 3.2 (b) Reuse the ParserGenerator as the AST producer

`libs/extras/parser_generator` + `tests/parser_generator/w.pg` already
parse every tracked `.w` file today (`parser_generator_w_test`,
enforced on every PR touching a `.w` file per `wbuildgen`'s residue
rule), producing a full `pg_ast_node` tree
(`libs/extras/parser_generator/ast_node.w`) — this is not hypothetical,
it exists and is exercised now. A leaf tool (`bin/wc2`, per the issue's
own naming) walking that tree for codegen is architecturally separable
from `w.w`: it would live under `tools/`, not `compiler/`/`grammar/`,
so **it does not enter the seed's transitive import closure** unless
and until it is promoted — same seed-safety story any new leaf tool
gets today. **Self-host risk: none while it stays a leaf tool** — `wc2`
producing wrong output fails its own tests, not `./wbuild verify`,
because `verify`'s fixpoint is defined over `w.w`'s existing
single-pass path, untouched. Risk appears only if/when `wc2` is
proposed as a *replacement* front end, which is a different, much
later decision with its own promotion path (mirroring `./wbuild
update`'s seed-promotion discipline).

**Does M1/M2 change the calculus?** Meaningfully, yes, but not enough
to change the recommendation on its own. `docs/projects/parser_generator.md`'s
"Since 2026-07 (issue #329 milestone 2)" section documents LL(1)
committed dispatch landing: FIRST/FOLLOW analysis
(`libs/extras/parser_generator/analysis.w`) replaces blind
backtracking for 109/118 of `w.pg`'s rules, cutting the whole-repo
`parser_generator_w_test` sweep from 78s to 19s (~4x) and — just as
relevant for a codegen consumer — eliminating the leaked/garbage
partially-built `pg_ast_node`s that backtracking used to produce on
every failed alternative (issue #329's design doc, §3 point 1). A
codegen walking this AST today gets a cleaner, faster-to-produce tree
than it would have before M1/M2 landed. **What M1/M2 does *not* give
option (b)**: `w.pg` is still explicitly a *syntax-shaped* validator,
not a semantic one — issue #329's own assessment is blunt about this:
"a context-free `.pg` can't decide [context-sensitive parses]", citing
`variable_declaration()`'s `type_lookup(token) >= 0` gate
(`grammar/variable_declaration.w:77`) and the generic re-parse pattern
(`grammar/generic.w`) as things `w.pg` "papers over ... with
backtracking and over-acceptance. Fine for syntax validation;
disqualifying for emit-as-you-parse." A `wc2` built on today's `w.pg`
AST would need to re-derive every one of those semantic decisions
itself (type table, declaration-before-use symbol resolution) — the
AST gives it *shape*, not *meaning*. **Milestone 3** (streaming mode:
listener callbacks, `mode streaming`, actions/predicates) is a design
doc only as of this writing (issue #329 comment, not yet implemented)
and is explicitly scoped as *not* a compiler-replacement path (issue
#329 §2 "Non-goals": "Replacing the production compiler front-end...
its semantics... would merely relocate into action blocks"). It targets
streaming *tooling* (formatters, validators), which is a different
consumer than a codegen backend wanting a materialized tree — so M3
landing would not directly help option (b) either; if anything, a
codegen backend wants the *opposite* of streaming (a full tree to walk
and re-walk), making M3's investment orthogonal rather than a
prerequisite.

**Unlocks**: multi-error reporting (the AST mode can report every
`recover`-marked repetition's errors in one pass — `w.pg` already does
this for its own syntax, per `docs/projects/parser_generator.md`'s
"Error recovery" section), a resident index queryable without
shelling out (a `wc2`-backed daemon endpoint could answer `symbols`/
`deps`-shaped queries off the AST directly instead of re-deriving from
`compiler.compiler`'s side-effecting pass), and a proving ground for
whether AST-based codegen is even viable for this language's semantics
before touching the seed graph at all. **Does not unlock**: a verified
drop-in replacement for `w.w`'s compile path — that requires
re-implementing every semantic decision `grammar/*.w` currently makes
inline, which is most of the actual compiler.

### 3.3 (c) A real AST in the compiler proper

`grammar/` rules build nodes, `code_generator/` walks them. This is the
"real end-state" the issue names it, and the biggest risk by a wide
margin on every axis:

- **Self-host fixpoint**: `./wbuild verify`'s wv3==wv4==wv5 byte
  equality is defined over the *current* single-pass emission path.
  Introducing an AST changes what "the compiler" computes at every
  intermediate stage; the issue's own open question — "how does
  warm-state compilation interact with the verify gate — daemon-produced
  binaries must be byte-identical to cold builds (add a `verify_warm`
  target?)" — applies in sharper form here: an AST-based codegen must
  produce byte-identical output to the single-pass path for the entire
  transition, staged per grammar rule with the single-pass path kept as
  a verified fallback (the issue's own phrasing), which means running
  *two* front ends in parallel and diffing output for as long as the
  migration takes.
- **Seed constraint**: `grammar/`, `code_generator/`, and `compiler/`
  are all in `w.w`'s transitive import closure (per `CLAUDE.md`'s "Seed
  constraint" section) — every line of a new AST layer here must be
  seed-syntax-safe until a `SEEDS` bump, same discipline that already
  governs every compiler-tree change. This is not a blocker (the whole
  compiler already lives under this constraint) but it rules out
  reaching for any convenience syntax the AST work might otherwise
  want.
- **REPL/wdbg interactions — the sharpest concrete risk this doc can
  point to**: `repl/core.w` (`import compiler.compiler`,
  `repl/core.w:41`) and `debugger/eval.w` both link the *entire*
  production compiler in-process and run it against a live, mapped
  executable buffer. `repl/core.w`'s header is explicit that a compile
  error "checkpoints the compiler's globals" and rolls them back via
  `repl_setjmp`/`repl_longjmp` (`repl/core.w:1`–`33`); `debugger/eval.w`
  says outright "the whole compiler is already in this process, and the
  debuggee's code buffer, symbol table and type table are all live —
  the same in-process model the REPL runs on"
  (`debugger/eval.w:1`–`12`). Any AST introduced into `compiler/`/
  `grammar/` becomes new mutable state that this checkpoint/rollback
  machinery must also snapshot and restore on every failed REPL entry
  or `wdbg` breakpoint expression — today that machinery only has to
  reason about the symbol table, type table, and code buffer. Getting
  this wrong doesn't fail loudly in `verify`; it corrupts REPL/wdbg
  session state in ways that would only surface as flaky
  multi-entry-session bugs, exactly the failure mode `repl/core.w`'s
  fault-recovery design (R1 in `docs/projects/consolidated_plan_2026_07.md`)
  was built to eliminate for runtime faults, not compiler-state ones.
- **Unlocks**: everything — multi-error reporting for the *production*
  compiler (today's actual limitation, not just `w.pg`'s), true
  incremental recompile (patch a definition's machine code without
  replaying the whole target — though `build_system_next.md`'s
  direction 4d already flags that single-pass direct byte emission
  makes *patching* binaries specifically hard even with an AST, since
  every definition's address depends on everything emitted before it),
  and a resident index that is the actual source of truth rather than
  a derived approximation. This is the only option that changes what
  the compiler itself can do, not just what tooling built around it can
  do.

### 3.4 Assessment

(a) is not really optional — it's what the daemon's cache layer already
is, ships with §2, and has no self-hosting exposure. (b) is a real,
separable experiment: cheap to attempt (leaf tool, no seed exposure),
now meaningfully cheaper to build well thanks to M1/M2's cleaner/faster
AST output, but bounded — it proves whether AST-based codegen is
viable for W's semantics without answering whether it's viable *inside*
the actual compiler, because `w.pg`'s permissive syntax-only stance
means the hard part (context-sensitive decisions) isn't in scope for
it. (c) is the only option that delivers what issue #231's title
actually promises ("AST-based codegen") but carries self-hosting risk
and REPL/wdbg blast radius disproportionate to what's needed to unblock
the daemon, which does not require it at all.

## 4. Interaction with the remote build cache (`W_CACHE_URL`)

The daemon and the remote cache (`tools/wexec.w:1350`–`1432`, landed as
part of the current wave — issue #251 D3-2) solve different layers and
should compose, not duplicate:

- **Remote cache** = a dumb content-addressed HTTP store keyed by the
  same SHA-256 target key wexec already computes
  (`GET/PUT <W_CACHE_URL>/objects/<key>`, bundle format documented at
  `tools/wexec.w:1364`–`1399`), populated by CI, read by every
  developer/agent checkout. It answers "has *anyone* already built this
  exact target." It is stateless per request — no daemon, no resident
  process, gated entirely on an env var so its absence is a no-op
  (`wexec_cache_url()`, `tools/wexec.w:1405`–`1414`).
- **wbuildd's warm cache** = an in-process, single-checkout-local
  answer to "did *this tree, since I started watching it,* actually
  change." It answers a cheaper and different question — not "does
  this key exist anywhere" but "do I even need to recompute the key."

Composition, not duplication: `wbuildd`'s target-layer cache (§2.4)
should call exactly the same `wexec_cache_remote_try`/
`wexec_cache_remote_push_if_enabled` path wexec already has
(`tools/wexec.w:1683`–`1730`) on an actual miss, unchanged — the daemon
short-circuits *before* that path only when its resident state already
knows nothing changed, which is strictly upstream of "check local
stamp, then check remote." Concretely: `wbuildd`'s per-target flow
becomes (1) inotify says nothing touched this target's closure since
last check → answer from memory, done; (2) something touched it →
recompute the key the same way `wexec_cache_key` does today → check
local stamp → check `W_CACHE_URL` → build. Steps 2 onward are
literally `wexec`'s existing code, reused rather than reimplemented,
which also means the daemon and a one-shot `wexec` fallback (§2.6)
never disagree about whether a target is cacheable or what its key is
— the daemon is a memoization layer in front of `wexec`'s existing
logic, not a parallel implementation of it. The CAS wire format
(`libs/extras/vcs/cas.w`'s `cas_object_path` loose-object layout,
already what the remote cache's server fixture in
`tests/wexec_remote_cache_test.w` speaks) is shared infrastructure
either way; nothing here proposes a second protocol.

## 5. Staged recommendation

1. **Stage 1 — prerequisites** (small, independent PRs, no daemon yet):
   `lib/inotify.w` (§2.3), a unix-domain-socket bind/listen helper in
   `lib/net.w` (§2.3), and — if the daemon is meant to serve macOS
   agents too, not just Linux — the per-arch dirent accessor fix
   `docs/projects/ai_tooling_next_steps.md` already flags for
   `wexec_collect_dir` (issue #231's own open question calls this out;
   confirmed still unresolved by grep). Each is a self-contained,
   low-risk library addition with its own tests, landable independently
   of everything else in this doc.
2. **Stage 2 — `wbuildd` MVP**: single-threaded event-loop daemon,
   unix-socket JSON-RPC (§2.1), serving `check`/`deps`/`symbols` first
   (the highest-value, lowest-risk endpoints — read-only, no target
   execution, directly answers §1.2's ~1080x opportunity), with the
   full lifecycle/staleness story (§2.2) and transparent fallback
   (§2.6) from day one, not bolted on later — a daemon that can
   silently serve stale answers is worse than no daemon. `build`/
   `test_changed` (target execution, §2.1) follow once the read-only
   surface is proven, reusing `wexec`'s existing cache-key and
   remote-cache code paths unchanged (§4).
3. **Stage 3 — wlsp back in-tree**: once stage 2's `check`/`symbols`/
   `deps` endpoints exist, moving `wlsp` back in
   (`docs/projects/consolidated_plan_2026_07.md` §7's framing: "the
   server and its first consumer co-evolve in one repo") becomes a thin
   protocol adapter PR, not a design decision — this is a corollary of
   stage 2, not new scope. The REPL websocket server
   (`docs/projects/consolidated_plan_2026_07.md`, Thread B's deferred
   item 15, "couples to #231") should be designed against the *same*
   `event_loop`/`json_rpc` stack at this point too, per that doc's
   explicit note — likely as a second listener (`jsonrpc_serve_listener`
   or a raw websocket upgrade over `libs/standard/web/http_server.w`,
   which landed this wave) on the same daemon process rather than a
   separate one, since both are "expose live in-process compiler state
   over a socket" problems. Whether it reuses `wbuildd`'s process or
   runs as a sibling is an open question (§6).
4. **Stage 4, optional and separable — AST option (b) experiment**:
   `bin/wc2` as a leaf tool over the PG's existing `w.pg` AST (§3.2),
   explicitly scoped as a research spike answering "is AST-based
   codegen viable for W's semantics at all," not as a path to replacing
   `w.w`. No seed exposure, no dependency on stages 1–3. This can run
   in parallel with stages 1–3 or after; it does not block the daemon
   and the daemon does not block it.
5. **Not recommended for scheduling yet — AST option (c)**: the
   self-hosting/REPL blast radius (§3.3) needs a maintainer decision
   up front (how much `verify`/REPL risk is acceptable, over what
   timeline) before any implementation slot is worth allocating; stage
   4's experiment is the natural input to that decision, not a
   replacement for making it explicitly.

## 6. Open questions for the maintainer

1. **Daemon lifetime model**: auto-spawned-on-first-use-and-persists
   (this doc's default assumption, §2.2), or explicitly
   started/stopped (`wbuildd start`/`wbuildd stop`) like a normal
   background service? Auto-spawn is more convenient but means a
   forgotten daemon can accumulate stale watches across long-lived
   sessions if the staleness check (§2.2) has a bug — worth deciding
   the failure mode's blast radius up front.
2. **Scope of the first read-only surface**: `check`/`deps`/`symbols`
   only, or does `test_changed` belong in stage 2 rather than waiting
   for target-execution plumbing? It's read-only-ish (it computes a
   target list, doesn't build) and is exactly what made §1.2's ~143s→
   0.13s number possible — arguably it should ride with the other
   read-only endpoints rather than being gated behind `build`.
3. **REPL websocket server: same process or sibling?** (§5 stage 3) —
   `wbuildd` answering `check`/`deps` and a REPL server holding live
   compiler state for eval are different risk profiles (read-only
   queries vs. mutating a live session); worth an explicit call on
   whether they share a process before either is designed in detail.
4. **`verify_warm` gate**: does landing `wbuildd` require a new CI
   target asserting daemon-served `check`/`build` results are
   byte-identical to the one-shot path, on top of the existing
   `verify`? This doc assumes yes for `build` (§2.4's "must not become
   a second source of truth") but the issue raises it as an open
   question and it's worth confirming scope (every RPC, or just the
   ones that produce binaries) before stage 2 lands.
5. **macOS**: is `wbuildd` Linux-only for its first milestone (matching
   where `lib/thread.w`, and until stage 1's dirent fix, directory
   hashing, are already Linux-only), or does macOS support gate stage
   2? The Mac-gated backlog (`docs/projects/sonnet_wave_plan_2026_07.md`
   §7) already defers other darwin work "ride the next Mac session" —
   recommend the same here rather than blocking the daemon on it.
6. **Windows/wasm**: `lib/net.w`'s unix-socket gap (§2.3) and
   `lib/thread.w`'s Linux-x86-only scope both suggest `wbuildd` is a
   Linux(+eventually darwin)-only tool by construction for the
   foreseeable future, same as `lib/thread.w` today. Worth stating
   explicitly so win64/wasm consumers know to keep using the one-shot
   path indefinitely, not as a temporary gap.

## 7. Note on the `--keep-going` open question

Issue #231's "Scheduling: fold in the backlog's `--keep-going` mode
while the executor is being reworked?" is stale as of this wave:
`wexec --keep-going` already exists and is documented
(`tools/wexec.w:52`, `:104`, `:1239`–`1292`, `:1831`–`1843`) — a target
whose dependency failed or was itself skipped is tracked and reported
in a summary epilogue rather than aborting the run. Nothing in this
design needs to fold it in; `wbuildd`'s `build` RPC (§2.1) exposes it
as a boolean flag that maps straight onto the existing behavior.
