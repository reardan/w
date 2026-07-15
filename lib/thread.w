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
here (`thread_spawn_ack`, each wthread's `done`) has exactly one writer
and one waiter and makes a single one-shot 0 -> 1 transition. W's
single-pass codegen emits a real load for every read and a real store
for every write (nothing is cached in registers across statements), and
x86-TSO makes stores visible in program order, so the worker's writes
to user data are visible to a joiner that has observed done == 1. The
futex syscall re-reads the word atomically in the kernel: FUTEX_WAIT
with expected value 0 returns immediately if the word is already 1, so
the wake cannot be lost. On x86-64 an int is 8 bytes while futex words
are 32-bit; the kernel sees the low half (the first 4 bytes, little
endian), which carries the full 0/1 value.

Constraints (MVP; see threads.md for staging):
- Only the main thread may call thread_spawn, thread_join and
  parallel_for: the handoff globals and the brk heap allocator are
  unsynchronized.
- Worker functions must not allocate (malloc/new/list/map/print
  formatting) or spawn; they compute into memory the caller provided.
- Worker stacks (4MB each) and wthread handles are not reclaimed on
  join: thread_create owns the mmap and does not expose it. A stack
  cache / thread pool is staged work.

API:
	type thread_fn = fn(void*) -> void
	type parallel_for_fn = fn(int, int, void*) -> void

	wthread* thread_spawn(thread_fn* func, void* arg)  # 0 on failure
	int thread_join(wthread* t)                        # 0, -1 on bad handle
	void parallel_for(int start, int end, int nthreads,
	                  parallel_for_fn* func, void* arg)

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
	int done         # 0 running, 1 finished; futex wait/wake target


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


# The zero-argument clone entry. Runs on the fresh 4MB stack; it must
# never return (there is no return address above it), so it exits the
# thread when the worker function comes back.
void thread_entry():
	wthread* t = thread_spawn_handoff
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
	thread_spawn_handoff = t
	thread_spawn_ack = 0
	int tid = thread_create(thread_entry)
	if (tid <= 0):
		return 0
	t.tid = tid
	thread_wait_word(&thread_spawn_ack)
	return t


# Block until t's worker function has returned. Futex-waits — no CPU
# is burned while the worker runs. Returns 0, or -1 for a null handle.
int thread_join(wthread* t):
	if (t == 0):
		return 0 - 1
	thread_wait_word(&t.done)
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
		else:
			workers.push(t)
		k = k + 1
	func(start, start + thread_chunk_offset(len, nthreads, 1), arg)
	for wthread* t in workers:
		thread_join(t)
