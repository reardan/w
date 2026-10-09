# Threads and `parallel_for` (`lib/thread.w`)

Design for the first usable threading layer: spawn-with-argument, a
blocking join, and deterministic `parallel_for` over an integer range —
the minimum numeric code needs to use more than one core.

Status: **implemented** for Linux x86 and x86-64 (`lib/thread.w`,
`thread_test`/`thread_64_test`, `parallel_for_test`/
`parallel_for_64_test`), including join-time stack/handle reclamation
(originally staged as item 2), host atomics and the futex
mutex/condvar (originally staged as item 3: `atomic_host_test`,
`thread_mutex_test` + 64-bit twins), and the persistent worker pool
behind `parallel_for` (the later staging item 2: `thread_pool_test` +
64-bit twin). Everything still under Staging is open.

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
  compile error with a fixture asserting it. The host pointer operand
  is checked like an ordinary `int*` call argument (the limb-intrinsic
  warn-on-mismatch rule) because `&x` — the natural host idiom — is
  W's untyped address-of constant, which the GPU path's hard pointee
  classification could never accept.
- `wmutex` (`mutex_init/lock/unlock`, the Drepper three-state futex
  mutex: uncontended lock/unlock is one lock-prefixed instruction, no
  syscall) and `wcond` (`cond_init/wait/signal/broadcast`, a wakeup
  sequence counter; spurious wakeups allowed, callers re-check their
  predicate in a loop) in `lib/thread.w`.

Also in (landed with the 2026-08b program):

- a persistent worker pool behind `parallel_for` (see Design): the
  chunks of every pooled call run on long-lived workers parked on
  per-worker futex words, so `parallel_for` in a loop stops paying
  one clone(2) + 4MB stack mmap per chunk per call. Purely a
  spawn-cost optimization — chunk boundaries, chunk 0 on the calling
  thread, completion-before-return and therefore results (including
  `lib/ndarray_par.w`'s bit-identity and two-phase reduction
  determinism) are unchanged. `thread_pool_init(n)` pre-spawns and
  pins the pool, `thread_pool_shutdown()` reclaims it through the
  ordinary join path.

Out (see Staging): every other target, spawning from non-main
threads.

## Design

**Spawn argument handoff.** The builtin's entry is zero-argument (the
clone child materializes out of a bare `ret`), so the library passes
the argument through a global: `thread_spawn` allocates a `wthread`
{tid, func, arg, done}, parks it in `thread_spawn_handoff`, clones the
internal `thread_entry`, and futex-waits on `thread_spawn_ack` until
the child has copied the pointer. Spawns are thereby serialized. The
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
The calling thread hands chunks 1..n-1 to the persistent pool (below),
runs chunk 0 itself, then blocks until every chunk completed.
`nthreads` is clamped to the range length; `nthreads <= 1` or an empty
range runs inline with no thread. Callback:
`fn(chunk_start, chunk_end, arg)`. The pre-pool spawn-per-chunk body
survives as `parallel_for_spawn` (each chunk boxed in a
`thread_chunk_task` so the 3-argument callback rides the 1-argument
spawn, all workers joined before returning): it is the fallback when
the pool cannot be created at all, and the path a nested call from a
chunk-0 callback takes; its own clone-failure fallback runs chunks
inline.

**Worker pool.** `parallel_for` used to clone one thread per chunk
per call, so a loop over `parallel_for` paid clone(2) + a 4MB stack
mmap per chunk per iteration; join-time reclamation already kept the
address space flat, making the pool purely a spawn-cost optimization.
Pool workers are spawned once (lazily by the first pooled call, sized
to its `nthreads - 1`, growing on demand so every chunk keeps its own
concurrent thread; or explicitly by `thread_pool_init(n)`, which pins
the size — wider calls then hand each worker a contiguous span of
chunks, same boundaries, different schedule) and park between jobs on
a per-worker futex word — no CPU burned while idle, no thundering
herd on wake. Dispatch is a per-worker mailbox (`wpool_slot`): the
main thread writes {fn, arg, range, chunk span}, resets the slot's
`done` word, bumps its `go` sequence word and futex-wakes it; the
worker runs one callback per chunk of its span, stores `done = 1` and
wakes that; the caller runs chunk 0 and futex-waits on each posted
slot's `done`. Every mailbox word keeps the module's
one-writer/one-waiter discipline (`go`: main writes, its worker
waits; `done`: the worker writes, main waits), so the plain-store
x86-TSO argument covers the pool with no new atomics: a worker reads
job fields only between observing a `go` bump and storing `done`, a
window in which the main thread never writes them, and the `go`
sequence makes a late-parking worker immune to job confusion (like
`wcond.seq`, aliasing needs 2^32 jobs between two of one worker's
park attempts). Nested `parallel_for` from a chunk callback is
sanctioned in both positions: on a pool worker it runs its chunks
serially in place (detected by the caller's stack pointer falling in
a pool worker's recorded 4MB stack mapping — spawn and pool dispatch
stay main-thread-only), on the main thread (chunk 0's callback, pool
busy) it takes `parallel_for_spawn`. `thread_pool_shutdown()` posts a
null job to each worker and `thread_join`s it — the standard
CLEARTID-gated munmap reclamation — then frees the mailboxes; without
it the parked workers last until process exit, their footprint
bounded by the largest `nthreads` any call used, which the spawn path
already paid concurrently during that call. Asserted by
`thread_pool_test` (+ 64-bit twin): 1000 pooled calls reuse exactly
the first call's workers, pinned pools run multi-chunk spans, nested
calls from both positions, wmutex contention from pool workers across
jobs, and repeated init/shutdown cycles; `ndarray_stage3_test` stays
the bit-identity canary.

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

**Constraints.** Main thread only for spawn/join/parallel_for and
thread_pool_init/thread_pool_shutdown (the handoff and pool globals
are unsynchronized), except the two sanctioned nested parallel_for
cases above; never call thread_pool_shutdown from a callback. Worker
functions must not spawn. They may allocate (see Allocator below), and
any thread may lock/unlock/wait/signal a mutex/condvar and use the
atomics.

**Thread-local storage.** `thread_entry` installs each spawned
thread's `thread_local` block, which is the bottom of its own stack
mapping, before the worker function runs. A PROT_NONE guard page sits
between that block (plus the thread's alternate signal stack) and the
stack proper, so overflowing a worker stack faults on the guard
(`thread_stack_guard`, issue #526). Pool workers keep theirs
across jobs. See docs/projects/thread_local.md.

**Allocator** (issue #498, `lib/thread_heap.w`). Workers used to be
barred from allocating because `lib/memory.w`'s free list and brk
growth are plain globals. Now every spawned thread allocates from its
own heap, mimalloc's model scaled down:

- `thread_spawn` installs the heaps before its first clone, through
  three hook words in `lib/memory.w`. The hooks are plain ints called
  as functions, so that seed-compiled file needs no new syntax, and a
  program that never spawns pays one null check per call.
- Each worker's heap (its pointer is the `thread_local` `th_heap`) has
  its own size-class bins and bump region in 1MB-aligned mmap
  segments. Allocating, and freeing the thread's own blocks, takes no
  lock and no atomic. The main thread keeps the unchanged brk free
  list.
- A two-level registry keyed by `address >> 20` maps each segment to
  its heap, so `free` finds a block's owner from the pointer alone.
  Addresses outside every segment belong to the main heap.
- Transfer: freeing another thread's block pushes it onto the owner's
  remote list, a lock-free stack (an `atomic_cas` push, and the owner
  takes the whole list at once, so there is no ABA). The owner files
  those blocks at its next malloc, and main drains its own list the
  same way. Blocks can cross threads in any direction, so a worker can
  build a `list` and hand it to main.
- At thread exit the heap is abandoned, not unmapped, and the next
  spawned thread adopts it along with its pending remote frees.
  Memory is therefore bounded by the peak number of live threads, and
  spawn/join loops reuse the same segments.
- Under `W_DEBUG_ALLOC` the hooks instead serialize the guard-page
  backend on one spin lock, so its checks still run.

Asserted by `thread_alloc_test` (+ 64-bit twin): concurrent
mixed-size churn with stamped blocks (the old shared allocator
segfaults on it), worker-built lists, maps and strings freed on main,
producer-to-consumer and worker-to-main transfer, 300 spawn/join
cycles, and allocating `parallel_for` callbacks. Threads created
through `pthread_create` or the raw `thread_create` builtin have no
heap and must not allocate.

## Memory-order contract (what x86/x64 code may rely on today)

W defines explicit ordering for its atomic intrinsics. The existing x86
thread library also relies on x86-TSO for several internal flags; those
implementation details must not be assumed by portable application code:

- **Compiler.** Atomic operations are observable accesses and ordering
  boundaries in both the streaming and retained AST paths. Their emitters
  clear local-load, constant and comparison folding notes; they are never
  treated as constant expressions. Register allocation excludes locals
  whose address escapes. Acquire/release/fence ordering is a language
  contract that future optimizations must preserve, rather than a reliance
  on every local currently being loaded from memory.
- **Plain word loads/stores** of naturally aligned words do not tear.
  On x86/x64 (TSO) loads are not reordered with loads, stores not with
  stores, and stores not with earlier loads, so a plain store acts as
  a release and a plain load as an acquire. A later load **may**
  complete before an earlier store to a different address is visible
  (the store buffer), so store-then-load handshakes (Dekker, Peterson,
  "set my flag, then read yours") are broken without a full barrier.
- **`atomic_add` / `atomic_cas`** are `lock xadd` / `lock cmpxchg` at
  full word width: atomic read-modify-writes that are full barriers
  (sequentially consistent), returning the old value. These two operations
  still require x86/x64; ARM64 read-modify-write lowering remains follow-up
  work.
- **`wmutex` / `wcond`** give the usual guarantee: everything written
  before `mutex_unlock` is visible to the next `mutex_lock` holder
  (lock is a `lock cmpxchg`, unlock a `lock xadd` plus, on the
  contended path, a plain store after it). Futex waits re-check their
  word in the kernel, so wakes are never lost. Prefer a mutex (never
  held across a task await) or a channel/executor to hand-rolled
  flags.
- **One-writer/one-waiter flags** (`wthread.done`, the pool mailboxes,
  lib/thread_heap.w's remote-free stack, which pushes with
  `atomic_cas`) rely on TSO's plain-store-is-release. They are correct
  on x86/x64 only.

The import-free word access and fence intrinsics are portable across
x86, x64 (including win64), ARM64 Linux and ARM64 Darwin:

| Intrinsic | Result | Memory ordering |
|-----------|--------|-----------------|
| `atomic_load(int* p)` | current `int` | acquire |
| `atomic_store(int* p, int value)` | `void` | release |
| `atomic_load_relaxed(int* p)` | current `int` | relaxed |
| `atomic_store_relaxed(int* p, int value)` | `void` | relaxed |
| `atomic_fence()` | `void` | sequentially consistent full fence |

The pointee must be a valid, naturally aligned `int`: 4 bytes on x86,
8 bytes on x64 and ARM64. Every access uses the full target word width;
packed or unaligned storage, smaller fields and invalid pointers are
outside the contract. Arguments evaluate once, left to right. Ordinary
symbols already defined at a call site shadow these names. Pointer/value
mismatches use the usual function-argument warnings (errors with `--strict`),
and wrong arity is an error. WASM and GPU bodies reject these host intrinsics
explicitly; they do not silently substitute ordinary accesses.

A release store synchronizes with an acquire load that observes it, making
all earlier writes visible to operations after the load. Relaxed operations
are indivisible word accesses, but do not publish unrelated memory. A full
fence orders earlier reads/writes before later reads/writes and participates
in sequentially consistent fence ordering (including store/fence/load
handshakes). Concurrent access to synchronization words must use the atomic
operations consistently. Use acquire/release publication or locks to protect
ordinary payload accesses; plain racing loads/stores have no portable
synchronization guarantee.

x86/x64 use full-width `mov` for acquire/release and relaxed accesses under
TSO. Their fence is `lock or dword [esp/rsp],0`, preserving the stack word
and value registers without requiring SSE2 on baseline x86. ARM64 uses
`ldar` / `stlr`, ordinary `ldr` / `str` for the relaxed forms, and `dmb ish`
for the fence. These ARM64 operations require normal shared memory in the
inner-shareable domain; they are not device/MMIO accessors.

`tests/atomic_host_test.w` exercises bidirectional payload publication and
store-buffer fence ordering with real x86/x64 threads.
`tests/atomic_order_codegen_test.w` checks instruction widths, folding
boundaries and A64 decoder/encoder round trips, and cross-compiles the
portable fixture for ARM64 Linux/Darwin and win64. The fixture also covers
streaming, required retained AST and optimized retained compilation. ARM64
runtime ordering still needs an ARM64 execution host; structural checks on
x86 do not replace that qualification. The checked-in
`python3 tools/qualify_native.py --suite atomic --rounds 20` command executes
publication and store-buffer/fence stress with concurrent forked workers sharing
normal memory, independently of the W thread runtime, in all three compilation
modes. It records hardware/OS/compiler settings and checks alignment and full
64-bit values. See [native ARM64 qualification](arm64_qualification.md) for
commands and the explicitly pending native Linux/Darwin evidence. Thread creation and mutex/condvar
ports on ARM64 remain separate work: existing runtime flags rely on x86
TSO until those ports adopt explicit acquire/release operations.

Cross-thread messages should transfer ownership: send an owned buffer
(the sender never touches it again and the receiver frees it, which
the per-thread heaps allow from any thread), or share an immutable
object with an explicit release (an `atomic_add` reference count, last
release frees). The mutex inside the channel or executor provides the
happens-before edge for the buffer's contents. Pointers into a task's
stack may cross only under a join-before-return wait
(`executor_run`, `task_spawn_blocking`); see docs/projects/async.md.

## Per-target support

| target       | state |
|--------------|-------|
| x86 Linux    | works (original stubs, now with futex join, join reclamation, atomics + mutex/condvar, worker pool) |
| x64 Linux    | works (new stubs, this project; same atomics + mutex/condvar, worker pool) |
| arm64 Linux  | no `thread_create` stub yet; `sys_clone`/futex are one syscall each away (`clone` 220, `futex` 98); acquire/release loads/stores and fences work; atomic add/cas still need LSE or ll-sc emitters |
| arm64_darwin | needs `bsdthread_create` + Mach futex equivalents (`ulock_wait`/`ulock_wake`); `sys_clone` is already an ENOSYS stub |
| win64        | needs `CreateThread` + `WaitOnAddress`; the Unix-primitive stubs return `-1` (the `lock xadd`/`cmpxchg` atomics themselves are OS-independent x86 and already emit for PE) |
| wasm32/WASI  | no threads (wasm threads proposal + shared memory; `thread_create` is a trap stub in `wasm_module.w`) |

## Staging

Done since the original cut: stack/handle reclamation on join (the
free-list variant was dropped — munmap-on-join gated on CLEARTID is
smaller and leaves no per-process cap), the x86/x64 half of
atomics + mutexes + condvars (host `atomic_add`/`atomic_cas`
intrinsics, `wmutex`, `wcond` — see Design), and the persistent
worker pool behind `parallel_for` (per-worker futex mailboxes, lazy
or `thread_pool_init`-pinned sizing, `thread_pool_shutdown`
reclamation, sanctioned nested calls — see Design; the spawn-per-chunk
path survives as the `parallel_for_spawn` fallback).

1. **arm64 Linux**: `thread_create` stub in `arm64_asm.w` (mmap +
   clone via `svc`), `sys_futex` wrapper; the library is already
   target-agnostic above the syscall layer. Host atomics want LSE
   (`ldadd`/`cas`) or an ll-sc loop behind the same
   `alu_atomic_add`/`alu_atomic_cas` seam, plus the target_isa
   dispatch the limb intrinsics use; then `grammar/atomic_builtin.w`
   can allow add/cas on ARM64 as well as the existing ordered loads/stores.
2. **Device/host atomic parity**: `atom.cas.b32` for `atomic_cas` in
   kernels (currently a compile error), and host `atomic_min`/
   `atomic_max` via a cmpxchg loop if a consumer appears.
3. **Darwin**: `bsdthread_create` spawn path and `ulock` wait/wake.
4. **win64 / wasm**: `CreateThread`+`WaitOnAddress`; wasm threads
   proposal — both far out.
