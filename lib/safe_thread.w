# Audited spawn/join for checked code (issue #699). Linux x86/x64 only,
# like lib/thread.w underneath. The compiler pins this exact implementation
# (compiler/safe_runtime.w) and exposes only safe_thread_spawn,
# safe_thread_join and safe_thread_fork_join to checked callers;
# docs/projects/safe_mode.md "Thread transfer and spawn/join" states the
# contract.
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
