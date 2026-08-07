/*
Kernel threads for numeric code: spawn-with-argument, a blocking join,
and parallel_for over an integer range (docs/projects/threads.md).

Linux x86/x86-64 ONLY. Spawning rides the thread_create builtin
(code_generator/{x86,x64}_asm.w): clone with CLONE_VM on a fresh 4MB
stack whose top slot holds the entry function. The builtin's entry is
zero-argument, so this module passes the argument through a handoff
global: thread_spawn stores the wthread* in thread_spawn_handoff,
clones thread_entry, and futex-waits until the child has copied the
pointer and acknowledged; only then can the next spawn reuse the
global. Joining futex-waits (no CPU spinning) on the thread's `done`
word, which the worker sets and futex-wakes when its function returns.
Other targets stay unsupported: arm64 has no thread_create stub yet and
Darwin threads need bsdthread_create (see threads.md staging).

Why plain word stores suffice (no atomics): every synchronization word
here (`thread_spawn_ack`, each wthread's `done` and `exited`) has
exactly one writer and one waiter and makes a single one-shot
transition (0 -> 1 for ack/done, 1 -> 0 for the kernel-cleared
exited). W's single-pass codegen emits a real load for every read and
a real store for every write (nothing is cached in registers across
statements), and x86-TSO makes stores visible in program order, so the
worker's writes to user data are visible to a joiner that has observed
done == 1. The futex syscall re-reads the word atomically in the
kernel: FUTEX_WAIT with the stale expected value returns immediately
if the word has already flipped, so the wake cannot be lost. On x86-64
an int is 8 bytes while futex words are 32-bit; the kernel sees the
low half (the first 4 bytes, little endian), which carries the full
0/1 value.

Reclamation: thread_join munmaps the worker's 4MB stack and frees the
wthread handle. done == 1 only means the worker *function* returned -
the worker still runs thread_wake_word/thread_exit on its stack after
that - so the joiner additionally waits for the kernel's exit signal:
each worker arms set_tid_address(&t.exited) on itself (the clone
builtin predates CLONE_CHILD_CLEARTID plumbing), and the kernel clears
that word and futex-wakes it only when the thread can never touch
userspace again, making the munmap race-free. thread_create does not
expose its mmap either, so the worker recovers the stack base itself
from its own stack pointer (see thread_entry).

Worker pool: parallel_for dispatches its chunks to a persistent pool
of workers (threads.md staging item 2) instead of cloning one thread
per chunk per call, so parallel_for in a loop pays the clone(2) + 4MB
stack mmap once per pool worker instead of once per chunk per
iteration. The pool is created lazily by the first pooled call (sized
to its nthreads - 1) and grows on demand, so every chunk still gets a
concurrent thread; an explicit thread_pool_init(n) pre-spawns and pins
n workers instead, and wider calls then hand each worker a contiguous
span of chunks. Idle workers park on a per-worker futex word (no CPU
burned, no thundering herd on wake). thread_pool_shutdown joins every
pool worker through the ordinary reclamation path above; without it
the workers (and their stacks) last until process exit, bounded by the
largest nthreads a call ever used - which the spawn path already paid
concurrently during that call. Chunk boundaries, chunk 0 running on
the calling thread, and completion-before-return are identical to the
spawn path, so results (including chunk-ordered float reductions, see
lib/ndarray_par.w) are bit-identical.

Mutex and condvar: wmutex is the classic three-state futex mutex
(Drepper, "Futexes Are Tricky") built on the host atomic_add/atomic_cas
intrinsics (lock xadd / lock cmpxchg, grammar/atomic_builtin.w) —
uncontended lock and unlock are one atomic instruction with no syscall,
contention futex-waits on the mutex word. wcond is a wakeup sequence
counter: cond_wait snapshots it under the mutex and futex-waits while
it still holds the snapshot, so a signal between the snapshot and the
park flips the counter and the wait returns immediately — the wake
cannot be lost. These are the multi-writer primitives: ANY thread may
use them (unlike spawn/join), and the lock-prefixed atomics are full
barriers, so a critical section's stores are visible to the next
holder.

Constraints (MVP; see threads.md for staging):
- Only the main thread may call thread_spawn, thread_join,
  parallel_for, thread_pool_init and thread_pool_shutdown: the handoff
  and pool globals and the brk heap allocator are unsynchronized. Two
  nested parallel_for cases are sanctioned: a chunk callback running
  on the main thread (chunk 0) may call parallel_for again (it takes
  the spawn path while the pool is busy), and a callback on a pool
  worker may too (its chunks run serially in place, same boundaries).
  Never call thread_pool_shutdown from a callback.
- Worker functions must not allocate (malloc/new/list/map/print
  formatting) or spawn; they compute into memory the caller provided.
  Allocate wmutex/wcond instances on the main thread too.
- thread_join frees the handle: join each handle exactly once, and
  read any wthread fields (tid, stack_base) before joining.
- cond_wait can wake spuriously (any bump wakes every parked
  snapshot): wrap it in a while loop that re-checks the predicate —
  the standard condvar contract. A signal with no waiter is lost, so
  the predicate itself must live in shared state under the mutex.

API:
	type thread_fn = fn(void*) -> void
	type parallel_for_fn = fn(int, int, void*) -> void

	wthread* thread_spawn(thread_fn* func, void* arg)  # 0 on failure
	int thread_join(wthread* t)  # 0, -1 on bad handle; reclaims stack + handle
	void parallel_for(int start, int end, int nthreads,
	                  parallel_for_fn* func, void* arg)

	int thread_pool_init(int nworkers)  # pre-spawn + pin the pool size
	void thread_pool_shutdown()   # join + reclaim every pool worker

	void mutex_init(wmutex* m)
	void mutex_lock(wmutex* m)
	void mutex_unlock(wmutex* m)   # only the locking thread may unlock
	void cond_init(wcond* c)
	void cond_wait(wcond* c, wmutex* m)  # call with m held, in a predicate loop
	void cond_signal(wcond* c)     # wake one waiter
	void cond_broadcast(wcond* c)  # wake all waiters

parallel_for splits [start, end) into nthreads deterministic contiguous
chunks (the first (end-start) % nthreads chunks get one extra element),
hands chunks 1..nthreads-1 to the persistent pool, runs chunk 0 on the
calling thread, then blocks until every chunk completed. The callback
receives (chunk_start, chunk_end, arg). nthreads is clamped to the
range length; nthreads <= 1 runs inline on the calling thread with no
thread; a pool that cannot be created at all falls back to the
spawn-per-chunk path, whose own clone-failure fallback is inline.
*/
import lib.lib


# Worker body: fn(arg).
type thread_fn = fn(void*) -> void

# parallel_for chunk callback: fn(chunk_start, chunk_end, arg).
type parallel_for_fn = fn(int, int, void*) -> void


struct wthread:
	int tid          # clone's child tid (informational)
	thread_fn* func
	void* arg
	int done         # 0 running, 1 worker function returned; futex target
	int stack_base   # mmap base of the worker's 4MB stack (worker-computed)
	int exited       # 1 until the kernel's exit-time CLEARTID store zeroes it


# Spawn handoff: the zero-argument clone entry reads its wthread* here.
# Valid only between thread_create and the child's ack; thread_spawn
# blocks on the ack before returning, so spawns are serialized.
wthread* thread_spawn_handoff
int thread_spawn_ack


# FUTEX_WAIT | FUTEX_PRIVATE_FLAG: these futexes are only ever shared
# between CLONE_VM threads of one process.
int thread_futex_wait_op():
	return 128


# FUTEX_WAKE | FUTEX_PRIVATE_FLAG.
int thread_futex_wake_op():
	return 129


# Block until *word becomes nonzero. The kernel re-checks the word
# under its own lock, so a wake between the load and the syscall just
# makes the syscall return immediately (EAGAIN); spurious wakeups
# re-loop.
void thread_wait_word(int* word):
	while (*word == 0):
		sys_futex(cast(int, word), thread_futex_wait_op(), 0, 0)


# Wake one waiter blocked on word (a no-op when nobody waits yet; the
# waiter's re-check in thread_wait_word covers that window).
void thread_wake_word(int* word):
	sys_futex(cast(int, word), thread_futex_wake_op(), 1, 0)


# Block until *word becomes zero: thread_wait_word in the other
# direction, for the kernel's exit-time CLEARTID store. Deliberately a
# plain (non-private) FUTEX_WAIT, op 0: the kernel's exit-time wake is
# a shared FUTEX_WAKE, whose hash key never matches a
# FUTEX_PRIVATE_FLAG waiter (glibc's join waits with LLL_SHARED for
# the same reason). The expected value passed to FUTEX_WAIT must be
# the same load the loop guard saw: with a fresh *word read in the
# call, a clear landing between the two loads would hand the kernel
# expected == 0 == current and sleep forever after the one-shot wake
# has already fired. With the single observed value, a clear before
# the syscall makes FUTEX_WAIT return EAGAIN immediately, so the wake
# cannot be lost.
void thread_wait_word_clear(int* word):
	int observed = *word
	while (observed != 0):
		sys_futex(cast(int, word), 0, observed, 0)
		observed = *word


# Size of the stack thread_create mmaps for each worker
# (code_generator/{x86,x64}_asm.w stack_create): 4MB.
int thread_stack_size():
	return 4194304


# The zero-argument clone entry. Runs on the fresh 4MB stack; it must
# never return (there is no return address above it), so it exits the
# thread when the worker function comes back.
void thread_entry():
	wthread* t = thread_spawn_handoff
	# Recover the stack mapping for the joiner's munmap: this frame sits
	# within the first page of the fresh stack (the entry sp starts one
	# word below stack_base + 0x3ffff0), so rounding a local's address
	# up to the next page boundary is exactly the mapping's end. The
	# base itself is only page-aligned, so only this top-relative
	# computation recovers it.
	int stack_end = (cast(int, &t) + 4095) & ~4095
	t.stack_base = stack_end - thread_stack_size()
	# Arm the kernel's exit signal before the ack so it is armed before
	# thread_join can possibly run: on this thread's exit the kernel
	# stores 0 to t.exited and futex-wakes it, after the thread's last
	# userspace instruction.
	sys_set_tid_address(cast(int, &t.exited))
	thread_spawn_ack = 1
	thread_wake_word(&thread_spawn_ack)
	t.func(t.arg)
	t.done = 1
	thread_wake_word(&t.done)
	thread_exit(0)


# Start func(arg) on a new thread. Returns a handle for thread_join,
# or 0 when clone fails. Main thread only.
wthread* thread_spawn(thread_fn* func, void* arg):
	wthread* t = new wthread()
	t.tid = 0
	t.func = func
	t.arg = arg
	t.done = 0
	t.stack_base = 0
	t.exited = 1
	thread_spawn_handoff = t
	thread_spawn_ack = 0
	int tid = thread_create(thread_entry)
	if (tid <= 0):
		free(cast(void*, t))
		return 0
	t.tid = tid
	thread_wait_word(&thread_spawn_ack)
	return t


# Block until t's worker function has returned, then reclaim it:
# munmap the worker's 4MB stack and free the handle. Futex-waits — no
# CPU is burned while the worker runs. The munmap waits for the
# kernel's CLEARTID exit signal (not just done == 1) so the worker is
# provably off its stack first. t is dangling after a 0 return: join
# each handle exactly once. Returns 0, or -1 for a null handle.
int thread_join(wthread* t):
	if (t == 0):
		return 0 - 1
	thread_wait_word(&t.done)
	thread_wait_word_clear(&t.exited)
	if (t.stack_base != 0):
		munmap(t.stack_base, thread_stack_size())
	free(cast(void*, t))
	return 0


# One parallel_for chunk, boxed for the void* spawn argument.
struct thread_chunk_task:
	parallel_for_fn* func
	int chunk_start
	int chunk_end
	void* arg


void thread_chunk_main(void* p):
	thread_chunk_task* task = cast(thread_chunk_task*, p)
	task.func(task.chunk_start, task.chunk_end, task.arg)


# Start offset of chunk k when len elements split n ways: the first
# len % n chunks get one extra element. k * (len / n) cannot overflow
# (it is bounded by len), unlike the k * len / n formulation.
int thread_chunk_offset(int len, int n, int k):
	int extra = k
	if (extra > len % n):
		extra = len % n
	return k * (len / n) + extra


# The original spawn-per-chunk parallel_for body: one fresh clone per
# chunk, all joined (stacks reclaimed) before returning. Kept as the
# fallback when the pool cannot be used: pool creation failed
# entirely, or a nested parallel_for from a chunk-0 callback on the
# main thread while the pool is busy with the outer call (safe here:
# both calls are on the main thread, so the spawn handoff and the
# allocator stay single-user). Chunk boundaries and chunk 0 on the
# calling thread are identical to the pooled path.
void parallel_for_spawn(int start, int end, int nthreads, parallel_for_fn* func, void* arg):
	int len = end - start
	if (len <= 0):
		return
	if (nthreads > len):
		nthreads = len
	if (nthreads <= 1):
		func(start, end, arg)
		return
	list[wthread*] workers = new list[wthread*]
	list[thread_chunk_task*] tasks = new list[thread_chunk_task*]
	int k = 1
	while (k < nthreads):
		thread_chunk_task* task = new thread_chunk_task()
		task.func = func
		task.chunk_start = start + thread_chunk_offset(len, nthreads, k)
		task.chunk_end = start + thread_chunk_offset(len, nthreads, k + 1)
		task.arg = arg
		wthread* t = thread_spawn(thread_chunk_main, cast(void*, task))
		if (t == 0):
			# clone failed: run this chunk on the calling thread
			func(task.chunk_start, task.chunk_end, arg)
			free(cast(void*, task))
		else:
			workers.push(t)
			tasks.push(task)
		k = k + 1
	func(start, start + thread_chunk_offset(len, nthreads, 1), arg)
	for wthread* t in workers:
		thread_join(t)
	# joined workers are done reading their task boxes
	for thread_chunk_task* task in tasks:
		free(cast(void*, task))
	__w_list_free(cast(__w_list*, workers))
	__w_list_free(cast(__w_list*, tasks))


# --- Persistent worker pool (threads.md staging item 2) ---
#
# Dispatch is a per-worker mailbox (wpool_slot): the main thread
# writes the job fields, resets `done`, bumps the slot's `go`
# sequence word and futex-wakes it; the worker runs its span of
# chunks, stores `done` = 1 and wakes that. Every mailbox word keeps
# this module's one-writer/one-waiter discipline (`go`: main writes,
# its worker waits; `done`: the worker writes, main waits), so the
# header's plain-store x86-TSO argument covers the pool with no new
# atomics. The worker reads job fields only between observing a `go`
# bump and storing `done` - a window in which main never writes them,
# because main posts a slot's next job only after having observed the
# previous `done`. `go` is a sequence (not a flag) so a worker that
# parks late can never confuse two jobs; like wcond's counter it
# would take 2^32 jobs between one worker's park attempts to alias
# (the kernel compares 32 bits).

struct wpool_slot:
	parallel_for_fn* func   # job callback; 0 tells the worker to exit
	void* arg
	int job_start           # the job's parallel_for start
	int job_len             # the job's end - start
	int job_chunks          # the job's total chunk count (its nthreads)
	int chunk_lo            # first chunk index this worker runs
	int chunk_hi            # one past the last chunk index it runs
	int go                  # job sequence: main bumps + wakes, worker parks
	int done                # 0 -> 1 when this worker finished the job
	int stack_lo            # worker's stack mapping base (nested detection)


list[wthread*] thread_pool_threads
list[wpool_slot*] thread_pool_slots
int thread_pool_size          # live pool workers
int thread_pool_cap           # 0 = grow per call; > 0 = pinned by init
int thread_pool_lists_ready
int thread_pool_busy          # a pooled job is in flight (main thread only)


# Pool worker main loop: park on this worker's own go word until the
# main thread posts a job, run the job's chunk span (one callback
# invocation per chunk, exact spawn-path boundaries), publish done,
# park again. A posted func of 0 is the shutdown request: returning
# falls back to thread_entry, which publishes the handle's done word
# and exits, so the ordinary thread_join reclaims stack and handle.
void thread_pool_worker(void* p):
	wpool_slot* slot = cast(wpool_slot*, p)
	int seen = 0
	while (1):
		# Park while go still holds the last handled sequence value.
		# The kernel re-checks the word atomically, so a bump between
		# the load and the syscall returns immediately (EAGAIN) - the
		# wake cannot be lost; a spurious wake just re-loops.
		while (slot.go == seen):
			sys_futex(cast(int, &slot.go), thread_futex_wait_op(), seen, 0)
		seen = slot.go
		parallel_for_fn* func = slot.func
		if (cast(int, func) == 0):
			return
		void* arg = slot.arg
		int job_start = slot.job_start
		int job_len = slot.job_len
		int job_chunks = slot.job_chunks
		int chunk_hi = slot.chunk_hi
		int k = slot.chunk_lo
		while (k < chunk_hi):
			int c0 = job_start + thread_chunk_offset(job_len, job_chunks, k)
			int c1 = job_start + thread_chunk_offset(job_len, job_chunks, k + 1)
			func(c0, c1, arg)
			k = k + 1
		slot.done = 1
		thread_wake_word(&slot.done)


# Grow the pool to at least n workers (main thread only, never while
# a job is in flight). Returns the live worker count, which stays
# short of n when a clone fails - callers distribute chunks over
# whatever exists and retry growth on the next call.
int thread_pool_ensure(int n):
	if (thread_pool_lists_ready == 0):
		thread_pool_threads = new list[wthread*]
		thread_pool_slots = new list[wpool_slot*]
		thread_pool_lists_ready = 1
	while (thread_pool_size < n):
		wpool_slot* slot = new wpool_slot()
		slot.func = cast(parallel_for_fn*, 0)
		slot.arg = cast(void*, 0)
		slot.job_start = 0
		slot.job_len = 0
		slot.job_chunks = 0
		slot.chunk_lo = 0
		slot.chunk_hi = 0
		slot.go = 0
		slot.done = 0
		slot.stack_lo = 0
		wthread* t = thread_spawn(thread_pool_worker, cast(void*, slot))
		if (t == 0):
			free(cast(void*, slot))
			return thread_pool_size
		slot.stack_lo = t.stack_base
		thread_pool_threads.push(t)
		thread_pool_slots.push(slot)
		thread_pool_size = thread_pool_size + 1
	return thread_pool_size


# Pre-spawn the pool so no later parallel_for pays a clone, and pin
# its size: a call with more chunks than workers then hands each
# worker a contiguous span of chunks instead of growing the pool
# (same chunk boundaries and results; only the schedule differs).
# Returns the live worker count (short when a clone fails; the pool
# never shrinks except through thread_pool_shutdown). nworkers < 1
# pins nothing and just returns the current size. Main thread only.
int thread_pool_init(int nworkers):
	if (nworkers < 1):
		return thread_pool_size
	thread_pool_cap = nworkers
	return thread_pool_ensure(nworkers)


# True when the calling thread is one of the pool's workers: the
# caller's stack pointer falls inside that worker's 4MB stack
# mapping. Workers only call this mid-job, when main never mutates
# the pool lists (growth and shutdown happen strictly between jobs),
# so the reads are stable. The subtraction keeps the range test
# correct even for a mapping straddling the signed-address boundary
# on 32-bit x86.
int thread_pool_on_worker():
	int probe = 0
	int here = cast(int, &probe)
	int w = 0
	while (w < thread_pool_size):
		int off = here - thread_pool_slots[w].stack_lo
		if (off >= 0 && off < thread_stack_size()):
			return 1
		w = w + 1
	return 0


# Stop and reclaim the pool: every worker is told to exit (func 0)
# and joined, which munmaps its 4MB stack and frees its handle - the
# same reclamation any join performs - then its mailbox is freed. The
# next parallel_for lazily builds a fresh unpinned pool. Optional:
# without it, pool workers just idle in futex_wait until process exit
# reaps them (nothing else accumulates per call). Main thread only;
# never call it from a parallel_for callback.
void thread_pool_shutdown():
	int w = 0
	while (w < thread_pool_size):
		wpool_slot* slot = thread_pool_slots[w]
		slot.func = cast(parallel_for_fn*, 0)
		slot.go = slot.go + 1
		thread_wake_word(&slot.go)
		thread_join(thread_pool_threads[w])
		free(cast(void*, slot))
		w = w + 1
	if (thread_pool_lists_ready != 0):
		__w_list_free(cast(__w_list*, thread_pool_threads))
		__w_list_free(cast(__w_list*, thread_pool_slots))
		thread_pool_lists_ready = 0
	thread_pool_size = 0
	thread_pool_cap = 0


# Run func over [start, end) split into nthreads contiguous chunks.
# The calling thread runs chunk 0 itself; chunks 1..nthreads-1 run on
# the persistent pool (created lazily on first use), and every chunk
# completes before the call returns. Deterministic: chunk boundaries
# depend only on (start, end, nthreads), exactly the spawn path's
# split. Main thread only, except the two sanctioned nested cases
# (see the header): a chunk-0 callback's nested call takes the spawn
# path, a pool worker's nested call runs its chunks serially in
# place.
void parallel_for(int start, int end, int nthreads, parallel_for_fn* func, void* arg):
	int len = end - start
	if (len <= 0):
		return
	if (nthreads > len):
		nthreads = len
	if (nthreads <= 1):
		func(start, end, arg)
		return
	if (thread_pool_on_worker() != 0):
		# Nested call on a pool worker: pool dispatch and spawn are
		# main-thread-only, so run the same chunks serially right here.
		int k = 0
		while (k < nthreads):
			int c0 = start + thread_chunk_offset(len, nthreads, k)
			int c1 = start + thread_chunk_offset(len, nthreads, k + 1)
			func(c0, c1, arg)
			k = k + 1
		return
	if (thread_pool_busy != 0):
		# Nested call from a chunk-0 callback on the main thread while
		# the pool runs the outer job: the slots are occupied, so pay
		# the clones like the pre-pool implementation always did.
		parallel_for_spawn(start, end, nthreads, func, arg)
		return
	int want = nthreads - 1
	if (thread_pool_cap != 0 && want > thread_pool_cap):
		want = thread_pool_cap
	int nworkers = thread_pool_ensure(want)
	if (nworkers == 0):
		# No pool at all (first clone failed): the spawn path, which
		# itself degrades to inline chunks when clones keep failing.
		parallel_for_spawn(start, end, nthreads, func, arg)
		return
	if (nworkers > nthreads - 1):
		nworkers = nthreads - 1
	thread_pool_busy = 1
	# Post chunks 1..nthreads-1 as balanced contiguous spans: worker w
	# takes span w of the same deterministic split over chunk indices
	# that the chunks themselves are over elements. With an unpinned
	# pool every span is exactly one chunk.
	int w = 0
	while (w < nworkers):
		wpool_slot* slot = thread_pool_slots[w]
		slot.func = func
		slot.arg = arg
		slot.job_start = start
		slot.job_len = len
		slot.job_chunks = nthreads
		slot.chunk_lo = 1 + thread_chunk_offset(nthreads - 1, nworkers, w)
		slot.chunk_hi = 1 + thread_chunk_offset(nthreads - 1, nworkers, w + 1)
		slot.done = 0
		slot.go = slot.go + 1
		thread_wake_word(&slot.go)
		w = w + 1
	func(start, start + thread_chunk_offset(len, nthreads, 1), arg)
	w = 0
	while (w < nworkers):
		thread_wait_word(&thread_pool_slots[w].done)
		w = w + 1
	thread_pool_busy = 0


# Three-state futex mutex (Drepper, "Futexes Are Tricky"): word 0 =
# unlocked, 1 = locked with no waiters, 2 = locked with possible
# waiters. On x64 the kernel sees the low 32 bits of the 8-byte word;
# the 0/1/2 values live entirely there (little endian).
struct wmutex:
	int word


void mutex_init(wmutex* m):
	m.word = 0


void mutex_lock(wmutex* m):
	# Fast path: 0 -> 1, one lock cmpxchg, no syscall.
	int c = atomic_cas(&m.word, 0, 1)
	while (c != 0):
		# Mark the mutex contended (1 -> 2) unless it already is, then
		# sleep while the word stays 2. An unlock between the mark and
		# the wait rewrites the word, so FUTEX_WAIT's atomic re-check
		# fails (EAGAIN) and the wake cannot be lost; a spurious wake
		# just re-loops.
		if ((c == 2) || (atomic_cas(&m.word, 1, 2) != 0)):
			sys_futex(cast(int, &m.word), thread_futex_wait_op(), 2, 0)
		# Retake as 0 -> 2, not 0 -> 1: other waiters may still be
		# parked, and only state 2 makes the eventual unlock wake them.
		c = atomic_cas(&m.word, 0, 2)


void mutex_unlock(wmutex* m):
	# 1 -> 0: nobody waits, done without a syscall. 2 -> 1: waiters may
	# exist — release the word and wake one, which retakes it as 2 (see
	# mutex_lock), keeping the wake chain alive for the rest.
	if (atomic_add(&m.word, 0 - 1) != 1):
		m.word = 0
		thread_wake_word(&m.word)


# Condition variable: a wakeup sequence counter (bumps are atomic —
# concurrent signalers race on it). Wakes can be spurious and a signal
# with no waiter is lost; see the header comment for the contract. A
# waiter can only miss a wake if exactly 2^32 signals land between its
# snapshot and its park (the futex compares 32 bits) — theoretical.
struct wcond:
	int seq


void cond_init(wcond* c):
	c.seq = 0


# Atomically release m and wait for a signal, then retake m. Call with
# m held, inside a while loop that re-checks the predicate. The
# snapshot is taken under the mutex, so a signaler that flips the
# predicate under the same mutex necessarily bumps seq after the
# snapshot: either the bump lands before the park (FUTEX_WAIT returns
# EAGAIN immediately) or the wake finds this waiter parked.
void cond_wait(wcond* c, wmutex* m):
	int observed = c.seq
	mutex_unlock(m)
	sys_futex(cast(int, &c.seq), thread_futex_wait_op(), observed, 0)
	mutex_lock(m)


# Wake one waiter.
void cond_signal(wcond* c):
	atomic_add(&c.seq, 1)
	thread_wake_word(&c.seq)


# Wake every waiter.
void cond_broadcast(wcond* c):
	atomic_add(&c.seq, 1)
	sys_futex(cast(int, &c.seq), thread_futex_wake_op(), 0x7fffffff, 0)
