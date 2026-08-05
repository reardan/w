# Threads and `parallel_for` (`lib/thread.w`)

Design for the first usable threading layer: spawn-with-argument, a
blocking join, and deterministic `parallel_for` over an integer range —
the minimum numeric code needs to use more than one core.

Status: **implemented** for Linux x86 and x86-64 (`lib/thread.w`,
`thread_test`/`thread_64_test`, `parallel_for_test`/
`parallel_for_64_test`), including join-time stack/handle reclamation
(originally staged as item 2), host atomics and the futex
mutex/condvar (originally staged as item 3: `atomic_host_test`,
`thread_mutex_test` + 64-bit twins). Everything still under Staging is
open.

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

Also in (landed after the original cut):

- join-time reclamation: `thread_join` munmaps the worker's 4MB stack
  and frees the handle, gated on the kernel's `set_tid_address`
  CLEARTID exit signal so the worker is provably off its stack first.
- host atomic intrinsics `atomic_add(int* p, int v)` /
  `atomic_cas(int* p, int expected, int desired)` on x86/x64
  (`grammar/atomic_builtin.w` + `lock xadd`/`lock cmpxchg` emitters in
  `code_generator/x86.w`), both returning the pre-update value. The
  names are shared with the GPU intrinsics and mean the same thing on
  both sides of a kernel launch; `atomic_min`/`atomic_max` stay
  device-only (a host lowering needs a cmpxchg loop) and `atomic_cas`
  host-only (no `atom.cas.b32` twin yet) — each direction is a
  compile error with a fixture asserting it.
- `wmutex` (`mutex_init/lock/unlock`, the Drepper three-state futex
  mutex: uncontended lock/unlock is one lock-prefixed instruction, no
  syscall) and `wcond` (`cond_init/wait/signal/broadcast`, a wakeup
  sequence counter; spurious wakeups allowed, callers re-check their
  predicate in a loop) in `lib/thread.w`.

Out (see Staging): every other target, thread pools, spawning from
non-main threads.

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

**Reclamation on join.** `thread_join` munmaps the worker's 4MB stack
and frees the `wthread` handle. `done == 1` only means the worker
*function* returned — the worker still runs its wake/exit tail on the
stack after that — so each worker arms `set_tid_address(&t.exited)` on
itself and the joiner also waits for the kernel's exit-time CLEARTID
clear (a *shared* futex wake, so that wait must not use
`FUTEX_PRIVATE_FLAG`) before unmapping. `thread_create` does not
expose its mmap, so the worker recovers the stack base from its own
stack pointer in the mapping's top page. Asserted by
`test_join_reclaims_stacks`: 1100 sequential spawn/joins must all
succeed (leaked stacks would exhaust a 32-bit address space) and must
reuse a bounded set of stack bases (the load-bearing check on x64).

**Atomics and mutex.** `mutex_lock` is Drepper's three-state futex
mutex over the host `atomic_cas`/`atomic_add` intrinsics: word 0 =
unlocked, 1 = locked, 2 = locked with possible waiters; the
uncontended paths are one `lock cmpxchg`/`lock xadd` with no syscall,
contention futex-waits on the word (value 2), and unlock from state 2
wakes one waiter, which retakes the lock as 2 to keep the wake chain
alive. The lock-prefixed instructions are full barriers on x86/x64,
so a critical section's plain stores are visible to the next holder.
`wcond` is a sequence-counter condvar: `cond_wait` snapshots the
counter under the mutex, unlocks, and futex-waits while the counter
still holds the snapshot; signal/broadcast bump-then-wake, so a
signal between snapshot and park makes the wait return immediately —
no lost wakeups, but wakes may be spurious and the predicate must be
re-checked in a loop.

**Constraints.** Main thread only for spawn/join/parallel_for (the
handoff globals and brk allocator are unsynchronized); worker
functions must not allocate or spawn, and mutex/condvar instances must
be allocated by the main thread — but any thread may lock/unlock/wait/
signal them, and use the atomics.

## Per-target support

| target       | state |
|--------------|-------|
| x86 Linux    | works (original stubs, now with futex join, join reclamation, atomics + mutex/condvar) |
| x64 Linux    | works (new stubs, this project; same atomics + mutex/condvar) |
| arm64 Linux  | no `thread_create` stub yet; `sys_clone`/futex are one syscall each away (`clone` 220, `futex` 98); host atomics need LSE or ll-sc emitters, `grammar/atomic_builtin.w` rejects them until then |
| arm64_darwin | needs `bsdthread_create` + Mach futex equivalents (`ulock_wait`/`ulock_wake`); `sys_clone` is already an ENOSYS stub |
| win64        | needs `CreateThread` + `WaitOnAddress`; the Unix-primitive stubs return `-1` (the `lock xadd`/`cmpxchg` atomics themselves are OS-independent x86 and already emit for PE) |
| wasm32/WASI  | no threads (wasm threads proposal + shared memory; `thread_create` is a trap stub in `wasm_module.w`) |

## Staging

Done since the original cut: stack/handle reclamation on join (the
free-list variant was dropped — munmap-on-join gated on CLEARTID is
smaller and leaves no per-process cap), and the x86/x64 half of
atomics + mutexes + condvars (host `atomic_add`/`atomic_cas`
intrinsics, `wmutex`, `wcond` — see Design).

1. **arm64 Linux**: `thread_create` stub in `arm64_asm.w` (mmap +
   clone via `svc`), `sys_futex` wrapper; the library is already
   target-agnostic above the syscall layer. Host atomics want LSE
   (`ldadd`/`cas`) or an ll-sc loop behind the same
   `alu_atomic_add`/`alu_atomic_cas` seam, plus the target_isa
   dispatch the limb intrinsics use; then `grammar/atomic_builtin.w`
   can lift its `target_isa != 0` rejection.
2. **Thread pool**: a persistent worker pool so `parallel_for` in a
   loop stops costing a clone per chunk (join-time reclamation already
   keeps the address space flat; the pool is now purely a spawn-cost
   optimization).
3. **Device/host atomic parity**: `atom.cas.b32` for `atomic_cas` in
   kernels (currently a compile error), and host `atomic_min`/
   `atomic_max` via a cmpxchg loop if a consumer appears.
4. **Darwin**: `bsdthread_create` spawn path and `ulock` wait/wake.
5. **win64 / wasm**: `CreateThread`+`WaitOnAddress`; wasm threads
   proposal — both far out.
