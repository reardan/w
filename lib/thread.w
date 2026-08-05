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
- Only the main thread may call thread_spawn, thread_join and
  parallel_for: the handoff globals and the brk heap allocator are
  unsynchronized.
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

	void mutex_init(wmutex* m)
	void mutex_lock(wmutex* m)
	void mutex_unlock(wmutex* m)   # only the locking thread may unlock
	void cond_init(wcond* c)
	void cond_wait(wcond* c, wmutex* m)  # call with m held, in a predicate loop
	void cond_signal(wcond* c)     # wake one waiter
	void cond_broadcast(wcond* c)  # wake all waiters

parallel_for splits [start, end) into nthreads deterministic contiguous
chunks (the first (end-start) % nthreads chunks get one extra element),
spawns workers for chunks 1..nthreads-1, runs chunk 0 on the calling
thread, then joins. The callback receives (chunk_start, chunk_end, arg).
nthreads is clamped to the range length; nthreads <= 1 (or a spawn
failure) runs inline on the calling thread with no clone.
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


# Run func over [start, end) split into nthreads contiguous chunks.
# The calling thread runs chunk 0 itself; chunks 1..nthreads-1 run on
# spawned threads, all joined before returning. Deterministic: chunk
# boundaries depend only on (start, end, nthreads). Main thread only.
void parallel_for(int start, int end, int nthreads, parallel_for_fn* func, void* arg):
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
