# Audited spawn/join for checked code (issue #699). Linux x86/x64 only,
# like lib/thread.w underneath. The compiler pins this exact implementation
# (compiler/safe_runtime.w) and exposes only safe_thread_spawn,
# safe_thread_join and safe_thread_fork_join, plus the synchronization API
# at the end of this file, to checked callers; docs/projects/safe_mode.md
# "Thread transfer and spawn/join" and "Synchronization: guarded mutexes
# and atomics" state the contracts.
#
# Ownership:
# - safe_thread_spawn[E, T](entry, payload) consumes `own T* payload`.
#   The checker requires T to be transferable (no borrowed lifetimes,
#   raw pointers or thread-affine markers anywhere in its owned graph)
#   and E to be exactly `fn[](own T*) -> int`.
# - Success returns a present handle. The child thread receives the
#   payload and passes it to entry exactly once; entry's own parameter
#   cleanup destroys it on the child. The parent never sees it again.
# - Failure (live-thread limit reached, or clone failed) returns an
#   absent handle. The payload never reached a thread; this function
#   destroys it before returning, through the ordinary recursive
#   owner cleanup of its parameter.
# - safe_thread_join consumes the handle, waits for the child to finish
#   and returns entry's result. Dropping a present handle without
#   joining (scope exit, replacement, early return) also waits for the
#   child, through the compiler-emitted __w_safe_thread_drop destructor,
#   so no checked thread outlives every owner of its handle.
# - safe_thread_fork_join[E, T](entry, left, right) lends two ref/refmut
#   pointers for the duration of the call: entry(left) runs on a new
#   thread while entry(right) runs on the caller, and the child is joined
#   before the call returns, so the lent storage outlives both. The result
#   is the sum of both entry results. When no thread can be started,
#   entry(left) then entry(right) run on the caller with the same result.
#
# Memory ordering: the child stores `result` before lib/thread.w's
# worker publishes done = 1 and exits; thread_join observes done and the
# kernel's exit-time CLEARTID store before the handle is read here, so the
# result is visible (x86-TSO plus the futex syscalls). No other memory is
# shared: the payload's whole owned graph is reachable only by the child.
# Shared mutation goes only through WSafeMutex guards and WSafeAtomic
# operations below.
import lib.thread

type __w_safe_thread_entry = fn(void*) -> int

struct WSafeThread:
	wthread* thread
	__w_safe_thread_entry* entry
	void* payload
	int result

# Markers. A record holding one of these as a field, at any depth of its
# reachable graph, opts out structurally. They are plain data, so they do
# not otherwise change the containing record's checked shape.
# WThreadAffine: neither transferable nor shareable across threads.
struct WThreadAffine:
	int reserved

# WThreadUnshared: transferable, but never reachable through a shared
# reference from two threads at once.
struct WThreadUnshared:
	int reserved

# Every live (spawned, not yet joined) checked thread holds one slot.
const int safe_thread_limit = 64

int __w_safe_thread_live


void __w_safe_thread_main(void* raw):
	WSafeThread* handle = cast(WSafeThread*, raw)
	void* payload = handle.payload
	handle.payload = 0
	handle.result = handle.entry(payload)


# Returns a started handle, or 0 with nothing started.
WSafeThread* __w_safe_thread_start(__w_safe_thread_entry* entry, void* payload):
	if (atomic_add(&__w_safe_thread_live, 1) >= safe_thread_limit):
		atomic_add(&__w_safe_thread_live, 0 - 1)
		return 0
	WSafeThread* handle = new WSafeThread
	handle.thread = 0
	handle.entry = entry
	handle.payload = payload
	handle.result = 0
	wthread* thread = thread_spawn(__w_safe_thread_main, cast(void*, handle))
	if (thread == 0):
		free(cast(void*, handle))
		atomic_add(&__w_safe_thread_live, 0 - 1)
		return 0
	handle.thread = thread
	return handle


int __w_safe_thread_finish(WSafeThread* handle):
	thread_join(handle.thread)
	int result = handle.result
	free(cast(void*, handle))
	atomic_add(&__w_safe_thread_live, 0 - 1)
	return result


# Compiler-emitted destructor for an unjoined present handle.
void __w_safe_thread_drop(WSafeThread* handle):
	__w_safe_thread_finish(handle)


optown WSafeThread* safe_thread_spawn[E, T](E* entry, own T* payload):
	WSafeThread* handle = __w_safe_thread_start(cast(__w_safe_thread_entry*, entry), cast(void*, payload))
	if (handle == 0): return cast(optown WSafeThread*, 0)
	# The child now owns the payload. Clear the checked parameter's home
	# so generated scope cleanup cannot destroy the transferred value.
	void** transferred = cast(void**, &payload)
	*transferred = cast(void*, 0)
	return cast(optown WSafeThread*, handle)


int safe_thread_join(own WSafeThread* thread):
	WSafeThread* handle = cast(WSafeThread*, thread)
	WSafeThread** transferred = cast(WSafeThread**, &thread)
	*transferred = cast(WSafeThread*, 0)
	return __w_safe_thread_finish(handle)


int safe_thread_fork_join[E, T](E* entry, T left, T right):
	__w_safe_thread_entry* code = cast(__w_safe_thread_entry*, entry)
	WSafeThread* handle = __w_safe_thread_start(code, cast(void*, left))
	if (handle == 0):
		int first = code(cast(void*, left))
		return first + code(cast(void*, right))
	int second = code(cast(void*, right))
	return __w_safe_thread_finish(handle) + second


# ---- Synchronization (#699 deliverable 4) ----
#
# WSafeMutex owns an int payload behind a lib/thread.w futex mutex.
# Checked code can reach the payload only through a held guard:
# - safe_mutex_new(own int* value) consumes the payload. The mutex is an
#   ordinary owner: dropping it destroys the payload once, then the mutex.
# - safe_mutex_lock(ref[a] WSafeMutex*) blocks until the lock is free and
#   returns own[a] WSafeGuard*: the guard keeps the shared borrow of the
#   mutex for as long as it lives, so the mutex cannot move or be dropped
#   first. safe_mutex_try_lock returns an absent guard instead of waiting.
# - The guard owner is the mutex's own address; it is never freed. Its
#   compiler-emitted destructor, __w_safe_guard_drop, unlocks. It runs at
#   every scope exit, return, break, continue and replacement, and when
#   safe_guard_unlock consumes the guard (that function's parameter cleanup
#   is the unlock). The checker treats each such drop as a use of the
#   guard's borrow and keeps guards on the thread that locked them.
# - safe_guard_value(refmut[a] WSafeGuard*) returns refmut[a] int*: a view
#   whose lifetime is a borrow of the guard, so it ends before the guard
#   can be released.
# Ordering: mutex_lock is a lock cmpxchg and mutex_unlock a lock xadd, both
# full barriers on x86/x64, so a holder's payload writes are visible to the
# next holder (docs/projects/threads.md "Memory-order contract").
#
# WSafeAtomic is a word whose every access goes through the operations
# below with an explicit WMemoryOrder. The checker requires the order to be
# a memory_order_* constant valid for the operation (C++11 rules); the
# runtime checks repeat that for unchecked callers and trap. Lowering on
# x86/x64 (TSO), argued in docs/projects/safe_mode_contracts.md:
#   load    relaxed: mov; acquire, seq_cst: mov
#   store   relaxed: mov; release: mov; seq_cst: mov, then full fence
#   fetch_add, compare_exchange (any order): lock xadd / lock cmpxchg

enum WMemoryOrder:
	memory_order_relaxed = 0
	memory_order_acquire = 1
	memory_order_release = 2
	memory_order_acq_rel = 3
	memory_order_seq_cst = 4


struct WSafeMutex:
	wmutex lock
	own int* value


# Compile-time shape only: the field gives the guard owner its one
# borrowed group (the mutex). A guard's address is its mutex's address.
struct WSafeGuard:
	ref[held] wmutex* lock


struct WSafeAtomic:
	int value


# Compiler-emitted destructor for a present guard: release the lock.
void __w_safe_guard_drop(WSafeGuard* guard):
	WSafeMutex* raw = cast(WSafeMutex*, guard)
	mutex_unlock(&raw.lock)


own WSafeMutex* safe_mutex_new(own int* value):
	WSafeMutex* mutex = new WSafeMutex
	mutex_init(&mutex.lock)
	int** slot = cast(int**, &mutex.value)
	*slot = cast(int*, value)
	# The mutex now owns the payload; clear the parameter's home so its
	# generated cleanup does not destroy it.
	int** transferred = cast(int**, &value)
	*transferred = cast(int*, 0)
	return cast(own WSafeMutex*, mutex)


own[a] WSafeGuard* safe_mutex_lock(ref[a] WSafeMutex* mutex):
	WSafeMutex* raw = cast(WSafeMutex*, mutex)
	mutex_lock(&raw.lock)
	return cast(own[a] WSafeGuard*, raw)


# One lock cmpxchg 0 -> 1, as mutex_lock's uncontended fast path.
optown[a] WSafeGuard* safe_mutex_try_lock(ref[a] WSafeMutex* mutex):
	WSafeMutex* raw = cast(WSafeMutex*, mutex)
	if (atomic_cas(&raw.lock.word, 0, 1) != 0): return cast(optown[a] WSafeGuard*, 0)
	return cast(optown[a] WSafeGuard*, raw)


refmut[a] int* safe_guard_value(refmut[a] WSafeGuard* guard):
	WSafeMutex* raw = cast(WSafeMutex*, guard)
	int** slot = cast(int**, &raw.value)
	return cast(refmut[a] int*, *slot)


# Consumes the guard; its parameter cleanup unlocks.
void safe_guard_unlock(own[a] WSafeGuard* guard):
	return


void __w_safe_atomic_order_trap():
	print_error("safe_atomic: invalid memory order\n")
	exit(1)


own WSafeAtomic* safe_atomic_new(int value):
	WSafeAtomic* atomic = new WSafeAtomic
	atomic.value = value
	return cast(own WSafeAtomic*, atomic)


int safe_atomic_load(ref WSafeAtomic* atomic, WMemoryOrder order):
	WSafeAtomic* raw = cast(WSafeAtomic*, atomic)
	if (order == memory_order_relaxed): return atomic_load_relaxed(&raw.value)
	if ((order != memory_order_acquire) && (order != memory_order_seq_cst)): __w_safe_atomic_order_trap()
	return atomic_load(&raw.value)


void safe_atomic_store(ref WSafeAtomic* atomic, int value, WMemoryOrder order):
	WSafeAtomic* raw = cast(WSafeAtomic*, atomic)
	if (order == memory_order_relaxed):
		atomic_store_relaxed(&raw.value, value)
		return
	if ((order != memory_order_release) && (order != memory_order_seq_cst)): __w_safe_atomic_order_trap()
	atomic_store(&raw.value, value)
	# A seq_cst store must not pass a later seq_cst load (store buffer).
	if (order == memory_order_seq_cst): atomic_fence()


# Returns the value before the addition.
int safe_atomic_fetch_add(ref WSafeAtomic* atomic, int delta, WMemoryOrder order):
	if ((order < memory_order_relaxed) || (order > memory_order_seq_cst)): __w_safe_atomic_order_trap()
	WSafeAtomic* raw = cast(WSafeAtomic*, atomic)
	return atomic_add(&raw.value, delta)


# Stores desired when the word equals expected. Returns the value observed
# before the operation: equal to expected exactly when the store happened.
int safe_atomic_compare_exchange(ref WSafeAtomic* atomic, int expected, int desired, WMemoryOrder success, WMemoryOrder failure):
	if ((success < memory_order_relaxed) || (success > memory_order_seq_cst)): __w_safe_atomic_order_trap()
	if ((failure == memory_order_release) || (failure == memory_order_acq_rel) || (failure < memory_order_relaxed) || (failure > memory_order_seq_cst)): __w_safe_atomic_order_trap()
	WSafeAtomic* raw = cast(WSafeAtomic*, atomic)
	return atomic_cas(&raw.value, expected, desired)
