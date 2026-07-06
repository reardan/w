# Plan: concurrency, scheduling, and parallel execution

## Target area

Base code directory: `libs/standard/concurrent/`

Suggested modules:

- `libs.standard.concurrent.sched`
- `libs.standard.concurrent.queue`
- `libs.standard.concurrent.futures`
- `libs.standard.concurrent.threading`
- `libs.standard.concurrent.multiprocessing`
- `libs.standard.concurrent.asyncio`
- `libs.standard.concurrent.context`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Lib/sched.py` - simple event scheduler.
- `Lib/queue.py` - synchronized queue semantics.
- `Lib/concurrent/futures/` - Future, Executor, ThreadPool, ProcessPool APIs.
- `Lib/threading.py` and `Modules/_threadmodule.c` - thread abstraction.
- `Lib/multiprocessing/` - process workers, pipes, queues.
- `Lib/asyncio/` - event loop, tasks, futures, streams.
- `Lib/contextvars.py` and `Modules/_contextvarsmodule.c` - context-local values.
- `Lib/subprocess.py` - process management patterns; W already has `lib.process`.

## Current W starting point

- `lib/event_loop.w` is a single-threaded poll/timer loop with callbacks.
- `lib/process.w` can spawn, pipe, wait, capture output, and enforce timeouts.
- Low-level syscalls expose `clone`, but W has no safe thread runtime, locks, or
  garbage collector.
- No closures; callbacks are plain function pointers with explicit context.

## Goals

1. Provide deterministic scheduling utilities over the existing event loop.
2. Add process-based futures before thread-based futures.
3. Add queues suitable for single-threaded/event-loop use first.
4. Design thread APIs only after stack, TLS, synchronization, and memory
   ownership rules are clear.
5. Keep `asyncio`-style naming as a future facade, not a premature full port.

## Non-goals for MVP

- No preemptive W threads in the first pass.
- No shared-memory multiprocessing.
- No coroutine syntax.
- No transparent cancellation across arbitrary user code.
- No contextvars until there is a task/thread abstraction.

## API sketch

`sched.w`

- `scheduler* sched_new()`
- `int sched_enter(scheduler* s, int delay_ms, int priority, sched_cb* cb, void* ctx)`
- `int sched_cancel(scheduler* s, int event_id)`
- `void sched_run(scheduler* s)`
- `void sched_run_pending(scheduler* s)`

`queue.w`

- `queue* queue_new()`
- `void queue_put(queue* q, void* item)`
- `void* queue_get(queue* q)`
- `int queue_empty(queue* q)`
- `int queue_size(queue* q)`
- Later: blocking/thread-safe queue.

`futures.w`

- `future* future_new()`
- `int future_done(future* f)`
- `void* future_result(future* f)`
- `char* future_error(future* f)`
- `void future_set_result(future* f, void* result)`
- `void future_set_error(future* f, char* error)`
- `int future_cancel(future* f)`

`multiprocessing.w`

- `process_executor* process_pool_new(int workers)`
- `future* process_submit(process_executor* ex, char* program, char** argv)`
- `void process_pool_shutdown(process_executor* ex)`
- MVP can execute external commands, not W function closures.

`asyncio.w`

- Thin facade over `lib.event_loop`:
- `event_loop* asyncio_new_event_loop()`
- `future* asyncio_sleep(event_loop* loop, int ms)`
- `future* asyncio_read(event_loop* loop, int fd, int max_bytes)`

`threading.w`

- Design-only initially:
- `thread* thread_start(thread_fn* fn, void* ctx)`
- `mutex* mutex_new()`, `mutex_lock`, `mutex_unlock`
- `condvar*` after futex support.

## Implementation phases

### Phase 1: scheduler

- Port the simple time/priority queue design from `sched.py`.
- Use monotonic milliseconds.
- Implement cancellation by id.
- Tests: ordering by time then priority, cancel, run_pending, reentrant schedule.

### Phase 2: queue

- Implement single-threaded FIFO over `structures.array_list` or built-in list.
- Add optional maxsize and nonblocking error returns.
- Tests: FIFO order, empty get behavior, maxsize full behavior.

### Phase 3: future primitive

- Implement state machine: pending, running, cancelled, finished, failed.
- Add callbacks as `fn(future*, void*) -> void` plus context pointer.
- Tests: set once, cancellation, callback order, error result.

### Phase 4: event-loop futures

- Bridge future completion to `lib.event_loop` timers/fd callbacks.
- Implement `sleep` and one fd read/write operation.
- Tests: sleep future completes, read future completes via socketpair/pipe,
  cancellation removes timer/watch.

### Phase 5: process executor

- Build on `lib.process.process_run`.
- Start with one submitted external command per worker.
- Later add a worker protocol for W functions if serialization exists.
- Tests: success command, failing command, timeout, multiple queued jobs.

### Phase 6: threading design spike

- Investigate `clone` wrapper, stack allocation/free, futex locks, TLS, signal
  interactions, and whether W runtime/global state is thread-safe.
- Do not expose public thread APIs until stress tests exist.

## Compatibility notes from Python

- Python `threading` is possible because CPython owns a mature runtime and GIL.
  W currently does not have equivalent safety rails.
- Python `asyncio` depends on coroutine syntax and task scheduling. W should use
  explicit callbacks/futures unless the language gains coroutines.
- Python `ProcessPoolExecutor` serializes callables and arguments. W can start
  with command execution and later add typed worker protocols.

## Acceptance criteria

- Scheduler, queue, and future primitives pass deterministic unit tests.
- Event-loop futures demonstrate timer and fd completion end to end.
- Process executor can run several external commands and collect statuses.
- Threading remains design-gated unless synchronization and runtime safety are
  proven by tests.
