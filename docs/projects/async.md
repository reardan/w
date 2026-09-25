# Async Design: tasks, awaitable I/O and a single-threaded scheduler

Status: phases 1-4 are implemented, plus the September 2026 expansion
(stages 1-6 in "Expansion" below): guard-paged sized stacks,
channels/select/locks, task groups and deadlines, the HTTP(S) stack on
tasks, an epoll backend, and a multi-threaded runtime. Phase 5 (syntax)
is still deferred. Everything is library code; the compiler, grammar
and seed are untouched.

| module | provides |
|---|---|
| `lib/task.w` | scheduler, spawn/go/join/cancel, fd waits, sleep, deadlines, task groups, wait queues, `task_dump` |
| `lib/task_chan.w` | `task_chan` (buffered / rendezvous, close) and `task_select` |
| `lib/task_sync.w` | `task_mutex`, `task_semaphore`, `task_event` |
| `lib/task_io.w` | `task_read`/`task_write_all`/`task_accept[_from]`/`task_connect_ipv4`, `task_process_run` |
| `lib/io_wait.w` | `io_wait`/`io_poll`: how protocol libraries park the calling task without importing the scheduler |
| `lib/task_runtime.w` | thread-per-core runtime, `task_xchan`, `task_spawn_blocking` (Linux x86/x64) |
| `lib/event_loop.w` | epoll (Linux) or poll backend, heap-ordered timers |

Tests: `task_test`, `task_chan_test`, `task_sync_test`, `task_io_test`,
`task_runtime_test`, `event_loop_test`, `http_server_task_test` (each
with a `_64` twin). Examples: `examples/web/task_echo_server.w`,
`examples/web/task_bench.w`.

## Problem statement

W programs that serve multiple connections today have two options, both
bad at scale or bad ergonomically:

- **Blocking sequential code** (`lib/net.w` calls directly): simple to
  write, but one slow peer stalls everything.
- **Callback style on `lib/event_loop.w`**: scales, but W has no
  closures, so every multi-step protocol becomes a hand-written state
  machine threading an explicit context pointer through callbacks
  (`event_fd_cb`/`event_timer_cb`). `lib/json_rpc.w` shows the shape —
  `jsonrpc_attach_connection` allocates a per-connection context
  struct and parses whatever bytes each `on_readable` callback brings;
  anything with more sequential steps gets worse fast.

We want straight-line code that scales:

```
generator int handle_client(int fd):
	while (1):
		int n = task_read(fd, buf, 4096)      # suspends, loop runs others
		if (n <= 0):
			break
		task_write_all(fd, buf, n)
	close(fd)
```

Many such tasks interleave on one thread; a task that would block
suspends, the scheduler runs whoever is ready.

## What already exists

The two halves of an async runtime are already built and tested:

| piece | file | provides |
|---|---|---|
| stackful coroutines | `lib/generator.w` | 64KB mmap'd stack per generator, `gen_switch` context switch (stubs in `code_generator/x86_asm.w` / `x64_asm.w`), create/next/value/done/free lifecycle |
| readiness + timers | `lib/event_loop.w` | poll(2) loop, fd watches with callback+context, one-shot/repeating/cancellable timers, safe removal during dispatch |
| non-blocking I/O | `lib/net.w`, `lib/poll.w` | `socket_set_nonblocking` (read returns `-EAGAIN`), poll masks/helpers, socketpair for tests |

What is missing is only the glue: a **task** abstraction that connects
"this generator is waiting on fd N / timer T" to the event loop, plus
await-style I/O helpers.

## Execution model decision

Same decision space as `docs/projects/iteration.md` faced for
generators, and the same answer for the same reason:

- **Stackless / state-machine transform (Python, Rust, C#) — rejected.**
  Requires compiling function bodies into resumable state machines:
  a second pass and an AST the single-pass compiler does not have, plus
  viral `async` function coloring through the type system.
- **Stackful tasks on the existing generator runtime (Go, Lua) —
  chosen.** Suspension state *is* the task's private machine stack.
  Any plain function called by a task can suspend the whole task; no
  new compiler transform, no function coloring, no new keywords for
  the MVP.
- **Single-threaded, cooperative — chosen.** One loop, one thread.
  Nothing on the multi-thread prerequisite list (atomics, futex
  mutexes, a thread-safe allocator, TLS, thread lifecycle) is needed:
  cooperative scheduling means nothing runs concurrently, so globals —
  including `lib/memory.w`'s free-list allocator — stay safe by
  construction. Python's asyncio, Node.js and OpenResty all prove this
  is a complete model. Multi-threading remains an explicit non-goal
  (see bottom).

## Suspension at depth (the key mechanism)

`yield` the *statement* is only legal directly inside a generator body,
but the *runtime* has no such restriction: `__w_gen_yield(g, value)`
switches stacks wherever it is called, and resuming returns into the
caller mid-function. The await helpers therefore do not need `yield`
syntax at all — they need the generator object, which the scheduler
publishes in a global before every resume:

```
generator* current_task_gen        # set by the scheduler, single thread

void task_await_fd(int fd, int events):
	# record what we wait on (task struct fields), then
	__w_gen_yield(current_task_gen, 0)
	# execution resumes here when the fd is ready
```

Validated experimentally: a generator body calling `helper()` calling
`await_value()` calling `__w_gen_yield(current, v)` suspends and
resumes correctly through both frames, repeatedly, on x86 and x64,
with today's `lib/generator.w` unchanged. This removes the only real
technical risk; everything below is library code.

Two conventions follow:

- **Task bodies never use `yield` directly.** The yield channel
  belongs to the runtime (wait requests); a stray body-level `yield`
  would be interpreted as one. Enforced by convention + a scheduler
  check first (unknown wait state = runtime error), possibly by a
  compile-time marker later (see "Syntax, later, maybe").
- **The scheduler is the only consumer** of task generators, which
  satisfies the single-consumer constraint (`caller_esp`/`resume_esp`)
  documented in `docs/projects/iteration.md`.

## Design

### Task object and wait protocol

New module `lib/task.w` (imports `lib.generator`, `lib.event_loop`,
`lib.poll`). A task wraps a generator plus its wait state; the yielded
word is unused — the wait request lives in the struct, the wake value
is written by the scheduler before resume:

```
struct task:
	generator* gen
	int state          # ready | waiting_fd | waiting_timer |
	                   # waiting_task | done
	int wait_fd        # valid in waiting_fd
	int wait_events    #   poll mask to register
	int wake_value     # delivered on resume: revents, or timer id,
	                   #   or joined task's result
	int result         # completion value, valid once done
	task* joiner       # task blocked in task_join on this one (0 if none)
	task_scheduler* sched
```

`task_scheduler` owns an `event_loop*` and a ready queue
(`array_list`). Suspension protocol, entirely in W:

1. Helper fills `wait_*` fields on the current task and calls
   `__w_gen_yield(current.gen, 0)`.
2. Control returns to the scheduler (which called `gen_next`). It
   inspects `task.state`: registers an fd watch
   (`event_loop_add_fd`, context = the task) or a timer, or requeues a
   `ready` task.
3. The watch/timer callback fires: it writes `wake_value` (revents /
   timer id), removes the watch, and pushes the task on the ready
   queue.
4. The scheduler pops ready tasks, sets `current_task_gen`, calls
   `gen_next`; the helper returns `wake_value` to straight-line task
   code.

Building on `lib/event_loop.w` rather than raw `lib/poll.w` is
deliberate: watches/timers/cancellation are already tested there, the
poll set is rebuilt per iteration anyway, and callback-style code and
task-style code can share one loop during migration.

### Public API (MVP)

```
task_scheduler* task_scheduler_new()
task*           task_spawn(task_scheduler* s, generator* g)
int             task_run(task_scheduler* s)        # until all tasks done
void            task_scheduler_free(task_scheduler* s)

# awaits — only legal inside a task; each returns a negative error
# (task_err_cancelled, task_err_timed_out) or the value described
int  task_await_fd(int fd, int events)             # returns revents
int  task_sleep_ms(int ms)                         # returns 0
int  task_yield_now()                              # reschedule, stay ready

# task-flavoured I/O (phase 2): retry-on-EAGAIN loops over lib/net.w
int  task_read(int fd, char* buf, int len)
int  task_write_all(int fd, char* buf, int len)
int  task_accept(int listen_fd)                    # returns nonblocking fd
int  task_connect_ipv4(int fd, int ip, int port)

# composition (phase 3)
int  task_join(task* t)                            # await completion, get result
int  task_cancel(task* t)
```

Errors follow the existing negative-errno convention (`lib/linux.w`);
there are no exceptions to propagate. `task_spawn(s, handler(fd))`
reads naturally because calling a generator function only creates the
object (`generator_call_suffix` in `grammar/generator_decl.w`).

Task bodies are declared with today's syntax, `generator int
name(args):` — no grammar change. The declared yield type is
meaningless for tasks (the runtime owns the channel); `int` by
convention.

### The scheduler loop

`task_run` drains the ready queue (resuming each task once per pass),
then calls `event_loop_run_once` to sleep until an fd or timer fires,
repeating until every spawned task is `done`. Ready-queue fairness is
FIFO. A CPU-bound task starves the loop — inherent to cooperative
scheduling; `task_yield_now()` is the pressure valve, and the
process-worker escape hatch (below) is the real answer.

### Completion, join, cancellation

- **Completion**: `gen_next` returning 0 marks the task `done`,
  records `result` (0 for MVP; a `task_finish(value)` helper can set
  it explicitly before returning), wakes a `joiner` if one is blocked,
  and the generator's stack is already reclaimed by `gen_next`'s
  existing done-path munmap.
- **Join**: `task_join` records the caller as `joiner` and suspends in
  state `waiting_task`; completion delivers `result` via `wake_value`.
- **Cancellation**: `task_cancel` removes any pending watch/timer and
  `gen_free`s the suspended generator. **Caveat, must be documented
  loudly**: freeing a suspended stack never resumes the body, so
  heap/fd cleanup after the suspension point does not run — same class
  of leak as `return` out of a `for` over a generator
  (`docs/projects/iteration.md`). Mitigations, in order of preference:
  structure tasks so resources are owned by the spawner; a
  cancellation-as-resume protocol (resume with `wake_value = -ECANCELED`
  and let awaits return the error so the body unwinds normally) is the
  better long-term design and worth prototyping in phase 3.
- **Timeouts**: an event-loop timer that cancels/wakes the operation —
  exactly the pattern `lib/event_loop.w`'s header comment describes;
  phase 3 wraps it as `task_await_fd_timeout(fd, events, ms)`.

### Memory budget

64KB of private stack per live task (`__w_gen_stack_size`) means
hundreds of tasks are cheap and thousands cost tens of MB of mostly
untouched anonymous mappings. Acceptable for the MVP; a
`stack_create_sized` variant was already anticipated in the generator
design if it ever pinches.

### Blocking work escape hatch

Blocking syscalls with no non-blocking variant, and CPU-bound work,
do not fit a cooperative loop. The sanctioned answer is **worker
processes, not threads**: `lib/process.w` + pipes watched by the same
event loop (`lib/framing.w` frames the messages). Separate address
spaces need no synchronization, no shared allocator, no ownership
rules. A `task_process_run(path, argv, out)` convenience (spawn + await exit +
capture output) belongs in phase 4.

## Syntax, later, maybe

The MVP adds **no grammar**. Whether syntax ever pays for itself:

- An `async`/`task` declaration marker (instead of reusing
  `generator`) would let the compiler reject body-level `yield` in
  tasks and give call sites a distinct static type (`task*` instead of
  `generator*`). Mechanically it is a rerun of the `generator` marker:
  `grammar/program.w` dispatch + a small decl module + an entry in
  `tests/parser_generator/w.pg` (the `parser_generator_w_test` target
  parses every tracked `.w` file and fails on unknown syntax).
- An `await` expression keyword buys nothing over plain helper calls —
  suspension needs no compiler cooperation here, unlike stackless
  designs.
- Bootstrap constraints if syntax lands: nothing under `compiler/`,
  `grammar/`, `code_generator/` or the auto-imported `structures/`
  runtime may *use* the new keywords until a seed update via
  `./wbuild update`; `lib/`, `tests/` and examples may, once `bin/wv2`
  exists.

Decision: defer. Revisit after phase 4 with real usage experience.

## Staged plan

Each phase lands independently green (`./wbuild tests`), with
`build.json` targets in both the x86 and x64 suites, mirroring
`generator_test`/`generator_64_test` and `event_loop_test`/
`event_loop_64_test`.

1. **Core runtime** — `lib/task.w`: task struct, scheduler,
   `task_spawn`/`task_run`, `task_await_fd`, `task_sleep_ms`,
   `task_yield_now`. Tests (`lib/task_test.w`, targets `task_test` +
   `task_64_test`): suspension-at-depth (the validated probe, made
   permanent); two tasks ping-pong over a `socket_pair`; sleep-based
   interleaving order; N tasks × M wakeups stress; scheduler exits
   when all tasks finish.
2. **Awaitable I/O** — `task_read`/`task_write_all`/`task_accept`/
   `task_connect_ipv4` (nonblocking setup + EAGAIN retry loops over
   `lib/net.w`). Test: echo server + several concurrent client tasks
   in one process, interleaving asserted; peer-close (`POLLHUP`/read 0)
   and error paths.
3. **Composition** — `task_finish`/`task_join`, `task_cancel`,
   `task_await_fd_timeout`; prototype cancellation-as-resume
   (`-ECANCELED` through awaits) and pick a default. Tests: join
   result delivery, cancel-while-suspended (watch removed, stack
   reclaimed), timeout fires vs. operation-wins race, joining an
   already-done task.
4. **Proof by port + process workers** — a task-based server example
   (per-connection task speaking the `lib/framing.w` protocol) to
   compare line-by-line against the callback-style connection handling
   in `lib/json_rpc.w`; `task_process_run` over `lib/process.w` +
   `lib/framing.w` for blocking/CPU work.
5. **Revisit syntax and polish** — decide the `task` marker question
   with usage data; sized stacks if task counts demand; docs update.

Phase 1 has no dependencies beyond what is committed today. Phases 2-3
depend only on 1. Phase 4 depends on 2 (and 3 for timeouts). Nothing
here touches the seed, `compiler/`, `grammar/` or `code_generator/`
until/unless phase 5 chooses syntax.

## Expansion (September 2026)

A review against Python asyncio, Tokio and smol found the core sound
(stackful tasks avoid function coloring; cancellation-as-resume runs
cleanup, unlike drop-cancellation) but the toolkit thin and nothing
real running on it. Six stages followed, each shipped with tests.

1. **Core hardening.** Every generator stack sits above a 16KB
   `PROT_NONE` guard, so an overflow faults instead of corrupting the
   neighbouring mapping. `gen_set_stack_size` moves a not-yet-started
   generator onto a bigger stack (its initial frame holds no pointers
   into itself), which `task_spawn_sized` / `task_group_spawn_sized`
   use. The run queue is a deque, fd watches are removed by handle
   (two tasks may wait on one fd), tasks can be detached (reclaimed on
   completion), joined by any number of tasks, named, and listed with
   `task_dump`.
2. **One park/wake path.** Every await registers what it waits on
   (an fd watch, a timer, waiters on wait queues) and parks; `task_wake`
   undoes all of it, so whichever event comes first wins and nothing
   stale is left behind. Wait queues are intrusive lists of
   `task_waiter`s living on the parked task's stack. Channels, select,
   the mutex, semaphore and event, joins and group waits are all
   "register waiters, park, read the waiter's status".
3. **Structured concurrency and deadlines.** `task_deadline_enter` /
   `_exit` bound every await in scope (nested scopes keep the nearer
   deadline; `task_go` and group children inherit it). A `task_group`
   owns its children: `task_group_wait` returns the first failure
   after cancelling the siblings, and a waiter that is itself cancelled
   or times out cancels the group and still waits the children out, so
   no child outlives the wait (Trio's nursery rule). Children are
   reclaimed as they finish, which keeps long-running accept loops
   bounded.
4. **The web stack on tasks.** Instead of rewriting the protocol code,
   its lowest I/O layer learned to park: on `EAGAIN`, `tls.w`'s record
   I/O, `connection.w`, `http_client.w` and `dns.w` call
   `io_wait`/`io_poll` (lib/io_wait.w). Inside a task that parks the
   task; outside, it fails at once (`io_wait`) or polls (`io_poll`), so
   blocking callers behave exactly as before. `server_context_serve_tasks`
   / `server_accept_task` serve one task per connection in a group, with
   the TLS handshake under a deadline scope; HTTP and HTTPS clients work
   from tasks too.
5. **Scaling the loop.** `lib/event_loop.w` uses level-triggered epoll
   on Linux (poll elsewhere, or via `event_loop_new_poll`), syncing
   interest per fd and dropping a registration eagerly when its last
   watch goes (so a close plus fd-number reuse cannot leave a stale
   cached mask). Regular files and closed fds, which epoll refuses, get
   the revents poll would report. Timers are a heap with an id map.
   With 2,000 idle parked tasks, 5,000 round trips take ~0.6s on epoll
   against ~6.7s on poll (`examples/web/task_bench.w`).
6. **Threads.** `lib/task_runtime.w` runs one scheduler per worker
   thread. Spawns and wakes cross threads through a per-scheduler
   inbox (a mutex-guarded list plus an eventfd the loop watches); tasks
   never migrate, so a task may keep pointers into its own stack and
   use thread-unsafe per-worker state. The current task becomes
   `thread_local` once the runtime is installed (lib/task.w reaches it
   through hooks, so it still compiles for every target).
   `task_xchan` is a mutex-protected channel whose parked peers are
   woken through their own worker's inbox; a wake carries the park
   sequence number it was meant for, so a wake that lost a race with a
   timeout is ignored. `task_spawn_blocking` runs a function on a
   helper thread while only the calling task waits.
   `http_server_threads.w` serves plain HTTP on N workers; HTTPS stays
   on one thread for now because the handshake's bignum/P-256 scratch
   values are module globals.

Found and fixed along the way: the built-in map never reclaimed
tombstones (add/remove churn eventually made a missing-key probe loop
forever), and `thread_spawn`'s handoff globals raced when two threads
spawned at once.

Follow-ups: per-call crypto scratch (then multi-threaded HTTPS);
work-stealing, if per-worker imbalance shows up in practice (tasks that
read `thread_local`s would need a rule before they may migrate);
kqueue for darwin; `task_runtime` on arm64 once threads and TLS land
there; the `task` declaration marker (phase 5).

## Non-goals (and what would change them)

- **Work-stealing M:N scheduling** (Go/Tokio-style). The
  thread-per-core runtime (stage 6) covers multi-core use; stealing
  would need a migration rule for tasks that use `thread_local`
  state and is only worth it if imbalance shows up.
- **io_uring**. epoll (stage 5) removed the O(n) poll scan; a
  completion-based backend would change the readiness model the
  protocol libraries rely on.
- **Closures / callbacks sugar**. Orthogonal language work; tasks are
  the answer to callback pain here.
