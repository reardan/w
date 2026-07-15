# Threads and `parallel_for` (`lib/thread.w`)

Design for the first usable threading layer: spawn-with-argument, a
blocking join, and deterministic `parallel_for` over an integer range —
the minimum numeric code needs to use more than one core.

Status: **implemented** for Linux x86 and x86-64 (`lib/thread.w`,
`thread_test`/`thread_64_test`, `parallel_for_test`/
`parallel_for_64_test`). Everything under Staging is open.

Motivation: the `thread_create`/`stack_create` builtins existed only on
the 32-bit x86 target, took a zero-argument function, and the only
consumer (`threading_test`) spin-waited on a shared flag. Real solver
work wants the 64-bit target, an argument, and a join that does not burn
a core.

## Scope

In:

- `thread_create`/`stack_create` builtins on x64
  (`code_generator/x64_asm.w`), mirroring the x86 stubs: clone with
  `CLONE_VM|FS|FILES|SIGHAND|PARENT|THREAD|IO` on a fresh 4MB
  `mmap`'d stack whose top slot holds the entry function, so the
  child's fall-through `ret` jumps straight into it.
- `sys_futex` wrappers (x86 syscall 240, x64 syscall 202) in
  `lib/__arch__/{x86,x64}/syscalls.w`.
- `lib/thread.w`: `thread_spawn(func, arg)` / `thread_join(t)` /
  `parallel_for(start, end, nthreads, func, arg)`.

Out (see Staging): every other target, mutexes/atomics/condvars,
thread pools, stack reclamation, spawning from non-main threads.

## Design

**Spawn argument handoff.** The builtin's entry is zero-argument (the
clone child materializes out of a bare `ret`), so the library passes
the argument through a global: `thread_spawn` allocates a `wthread`
{tid, func, arg, done}, parks it in `thread_spawn_handoff`, clones the
internal `thread_entry`, and futex-waits on `thread_spawn_ack` until
the child has copied the pointer. Spawns are thereby serialized, which
also keeps the (unsynchronized) brk allocator single-user. The
alternative — widening the builtin to `thread_create(func, arg)` — was
rejected because the stub would have to forge an argument frame for
W's stack convention on two targets; a library-side handshake is
smaller and testable.

**Join without spinning.** The worker stores `done = 1` and
`FUTEX_WAKE`s it after the user function returns; `thread_join` loops
`while (done == 0) FUTEX_WAIT(&done, 0)`. No atomics are needed:

- each word (`done`, `thread_spawn_ack`) has exactly one writer and
  one waiter and makes a single 0 -> 1 transition;
- W's single-pass codegen emits a real load/store per access (nothing
  is cached in registers across statements), so plain word accesses
  behave as volatile;
- x86-TSO makes stores visible in program order, so the worker's data
  writes precede its visible `done = 1`;
- the kernel re-reads the futex word atomically: `FUTEX_WAIT` with
  expected value 0 returns immediately if the word already flipped, so
  the wake cannot be lost.

Futexes use `FUTEX_PRIVATE_FLAG` (the threads share one address
space). Futex words are 32-bit; on x64 the kernel sees the low half of
the 8-byte `int`, which carries the whole 0/1 value on little-endian.

**`parallel_for(start, end, nthreads, func, arg)`.** Deterministic
contiguous chunking: chunk boundaries depend only on the arguments
(`len / nthreads` each, the first `len % nthreads` chunks one extra).
The calling thread spawns workers for chunks 1..n-1 (each boxed in a
`thread_chunk_task` so the 3-argument callback rides the 1-argument
spawn), runs chunk 0 itself, then joins. `nthreads` is clamped to the
range length; `nthreads <= 1`, an empty range, or a failed clone run
inline with no thread. Callback: `fn(chunk_start, chunk_end, arg)`.

**Constraints.** Main thread only for spawn/join/parallel_for; worker
functions must not allocate or spawn (the allocator is a shared brk
heap with no lock); worker stacks and handles are not reclaimed on
join (`thread_create` owns the mmap and does not expose the address) —
a long-running program should reuse workers via `parallel_for`'s
staged pool rather than spawning in a loop.

## Per-target support

| target       | state |
|--------------|-------|
| x86 Linux    | works (original stubs, now with futex join) |
| x64 Linux    | works (new stubs, this project) |
| arm64 Linux  | no `thread_create` stub yet; `sys_clone`/futex are one syscall each away (`clone` 220, `futex` 98) |
| arm64_darwin | needs `bsdthread_create` + Mach futex equivalents (`ulock_wait`/`ulock_wake`); `sys_clone` is already an ENOSYS stub |
| win64        | needs `CreateThread` + `WaitOnAddress`; the Unix-primitive stubs return `-1` |
| wasm32/WASI  | no threads (wasm threads proposal + shared memory; `thread_create` is a trap stub in `wasm_module.w`) |

## Staging

1. **arm64 Linux**: `thread_create` stub in `arm64_asm.w` (mmap +
   clone via `svc`), `sys_futex` wrapper; the library is already
   target-agnostic above the syscall layer.
2. **Stack reclamation / thread pool**: keep exited workers' stacks on
   a free list keyed by the library (requires the library to own the
   mmap instead of `stack_create`, or a `stack_create`/`stack_free`
   builtin pair), then a persistent worker pool so `parallel_for` in a
   loop stops costing a clone per chunk.
3. **Atomics + mutexes + condvars**: compiler builtins for
   `lock xadd`/`cmpxchg` (x86/x64) and LSE/ll-sc (arm64), then a futex
   mutex; needed before any multi-writer data structure.
4. **Darwin**: `bsdthread_create` spawn path and `ulock` wait/wake.
5. **win64 / wasm**: `CreateThread`+`WaitOnAddress`; wasm threads
   proposal — both far out.
