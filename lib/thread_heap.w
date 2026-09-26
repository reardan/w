/*
Per-thread heaps for lib/thread.w workers (issue #498,
docs/projects/thread_local.md "Allocator").

Linux x86/x86-64 ONLY, like lib/thread.w (which imports this module
and installs it on the first thread_spawn). Programs that never spawn
never install anything: malloc/free/realloc keep running the main
thread's lib/memory.w backend with no extra cost beyond one null
check per call.

Model (mimalloc's, scaled down):

- Every spawned thread owns a heap: its own size-class bins and bump
  region carved from 1MB-aligned mmap segments, never brk. malloc and
  a free of the thread's own blocks touch only that heap, with no lock
  and no atomics. The heap pointer lives in the thread_local th_heap.
- The main thread keeps the lib/memory.w backend (the brk free list)
  exactly as before; th_heap is 0 there.
- Ownership: every segment is recorded in a two-level registry keyed
  by address >> 20, so free() finds a block's owning heap from the
  pointer alone. Addresses outside any segment belong to the main
  heap.
- Transfer: a free of another thread's block pushes it onto the
  owner's remote list, a lock-free stack (atomic_cas push; the owner
  takes the whole list at once, so there is no ABA). The owner files
  those blocks into its bins at its next malloc. Frees of main-heap
  blocks from workers go to th_main_remote, which the main thread
  drains the same way. Blocks can therefore cross threads freely: a
  worker can build a list, hand it to main, and main frees it.
- Thread exit: the heap is abandoned (pushed on a spin-locked list,
  not unmapped) and adopted by the next thread spawned, remote list
  included, so memory is bounded by the peak number of live threads
  and spawn/join loops reuse the same segments.
- Under W_DEBUG_ALLOC (lib/memory_debug.w) the hooks instead serialize
  every call on one wmutex: the guard-page backend keeps its checks,
  it just stops being per-thread.

Block layout matches lib/memory_freelist.w's: a two-word header
[size][link] in front of the payload, size in payload bytes (a multiple
of 8). link is unused while the block is live, which is what lets the
remote lists thread through it for both kinds of heap.
*/
import lib.lib
import lib.memory


const int th_segment_shift = 20


int th_segment_size():
	return 1 << th_segment_shift


const int th_bin_count = 41


# Same size classes as lib/memory_freelist.w: exact 8-byte steps up
# to 256, then doubling ranges up to 65536, then one bin for the rest.
int th_size_bin(int size):
	if (size <= 256): return (size >> 3) - 1
	int limit = 512
	int b = 32
	while ((size > limit) && (b < 40)):
		limit = limit << 1
		b = b + 1
	return b


struct wheap:
	int remote           # blocks freed by other threads (header link chain)
	int bins             # th_bin_count() free-list heads
	int ptr              # bump region [ptr, end) in the current segment
	int end
	wheap* next_abandoned


thread_local wheap* th_heap
thread_local int th_is_worker

int th_main_remote       # main-heap blocks freed by workers
int th_registry          # word table: address >> 32 -> leaf (0 on x86)
int th_abandoned_lock    # spin word guarding th_abandoned
wheap* th_abandoned
int th_installed


# sched_yield: x86 158, x64 24.
void th_yield():
	if (__word_size__ == 8): syscall(24, 0, 0, 0)
	else: syscall(158, 0, 0, 0)


int th_mmap(int len):
	# PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS
	int p = mmap(0, len, 3, 0x22)
	if ((p < 0) && (p > -4096)): return 0
	return p


# A len-byte mapping (a multiple of the segment size) aligned to the
# segment size: over-map by one segment and trim both ends.
int th_segment_map(int len):
	int seg = th_segment_size()
	int raw = th_mmap(len + seg)
	if (raw == 0): return 0
	int aligned = (raw + seg - 1) & (0 - seg)
	if (aligned != raw): munmap(raw, aligned - raw)
	int tail = raw + seg - aligned
	if (tail > 0): munmap(aligned + len, tail)
	return aligned


int th_registry_hi(int addr):
	if (__word_size__ == 8): return (addr >> 32) & 32767
	return 0


int th_registry_mid(int addr):
	return (addr >> th_segment_shift) & 4095


int* th_registry_leaf(int addr, int create):
	int* top = cast(int*, th_registry)
	int hi = th_registry_hi(addr)
	int leaf = top[hi]
	if ((leaf == 0) && create):
		int fresh = th_mmap(4096 * __word_size__)
		if (fresh == 0): return cast(int*, 0)
		leaf = atomic_cas(&top[hi], 0, fresh)
		if (leaf == 0): leaf = fresh
		else: munmap(fresh, 4096 * __word_size__)
	return cast(int*, leaf)


# Owning heap of the block at addr, or 0 for the main heap.
wheap* th_owner(int addr):
	int* leaf = th_registry_leaf(addr, 0)
	if (leaf == 0): return cast(wheap*, 0)
	return cast(wheap*, leaf[th_registry_mid(addr)])


# Counted, not compared: on x86 a segment can end exactly at the top
# of the address space, where base + len wraps.
int th_register(int base, int len, wheap* h):
	int n = len >> th_segment_shift
	for i in range(n):
		int a = base + (i << th_segment_shift)
		int* leaf = th_registry_leaf(a, 1)
		if (leaf == 0): return 0
		leaf[th_registry_mid(a)] = cast(int, h)
	return 1


void th_bin_push(wheap* h, int block, int size):
	int* heads = cast(int*, h.bins)
	int* bw = cast(int*, block)
	int b = th_size_bin(size)
	bw[0] = size
	bw[1] = heads[b]
	heads[b] = block


# Point h's bump region at a fresh segment big enough for need bytes.
int th_heap_grow(wheap* h, int need):
	int seg = th_segment_size()
	int len = seg
	while (len < need): len = len + seg
	int base = th_segment_map(len)
	if (base == 0): return 0
	if (th_register(base, len, h) == 0):
		munmap(base, len)
		return 0
	# The old region's tail is lost to fragmentation only if it is too
	# small to file; otherwise it goes into its bin.
	int header = 2 * __word_size__
	int tail = h.end - h.ptr
	if (tail >= header + 8): th_bin_push(h, h.ptr, tail - header)
	h.ptr = base
	h.end = base + len
	return 1


wheap* th_heap_create():
	int seg = th_segment_size()
	int base = th_segment_map(seg)
	if (base == 0): return cast(wheap*, 0)
	wheap* h = cast(wheap*, base)
	if (th_register(base, seg, h) == 0):
		munmap(base, seg)
		return cast(wheap*, 0)
	# The record and its bin heads open the first segment (mmap zeroed
	# them); blocks bump up from the next 16-byte boundary.
	h.bins = base + 64
	int first = h.bins + th_bin_count * __word_size__
	h.ptr = (first + 15) & (0 - 16)
	h.end = base + seg
	return h


void th_lock_abandoned():
	while (atomic_cas(&th_abandoned_lock, 0, 1) != 0): th_yield()


void th_unlock_abandoned():
	atomic_cas(&th_abandoned_lock, 1, 0)


# A heap for a thread that is starting: adopt an abandoned one when
# there is one, else make a new one. 0 when the kernel refuses memory;
# the thread then falls back to the locked main heap.
wheap* th_heap_acquire():
	th_lock_abandoned()
	wheap* h = th_abandoned
	if (h != 0):
		th_abandoned = h.next_abandoned
		h.next_abandoned = cast(wheap*, 0)
	th_unlock_abandoned()
	if (h == 0): h = th_heap_create()
	return h


void th_heap_release(wheap* h):
	if (h == 0): return
	th_lock_abandoned()
	h.next_abandoned = th_abandoned
	th_abandoned = h
	th_unlock_abandoned()


# Push block (a header address) onto a remote list word.
void th_remote_push(int* rlist, int block):
	int* bw = cast(int*, block)
	int old = rlist[0]
	bw[1] = old
	while (atomic_cas(rlist, old, block) != old):
		old = rlist[0]
		bw[1] = old


# Take a whole remote list at once (0 when empty).
int th_remote_take(int* rlist):
	int old = rlist[0]
	while (old != 0):
		int seen = atomic_cas(rlist, old, 0)
		if (seen == old):
			return old
		old = seen
	return 0


void th_heap_drain(wheap* h):
	int block = th_remote_take(&h.remote)
	while (block != 0):
		int* bw = cast(int*, block)
		int next = bw[1]
		th_bin_push(h, block, bw[0])
		block = next


void th_main_drain():
	int block = th_remote_take(&th_main_remote)
	int header = 2 * __word_size__
	while (block != 0):
		int* bw = cast(int*, block)
		int next = bw[1]
		malloc_backend_free(cast(void*, block + header))
		block = next


void* th_heap_malloc(wheap* h, int size):
	if (h.remote != 0): th_heap_drain(h)
	if (size < 1): size = 1
	size = ((size + 7) >> 3) << 3
	int header = 2 * __word_size__
	int* heads = cast(int*, h.bins)
	int b = th_size_bin(size)
	int block = 0
	# First fit in the request's own bin (exact bins always fit on the
	# first block; the scan is capped like the main allocator's), then
	# the head of the first non-empty higher bin.
	int* prev = cast(int*, 0)
	int cur = heads[b]
	int misses = 0
	while ((cur != 0) && (misses < 16)):
		int* cw = cast(int*, cur)
		if (cw[0] >= size):
			if (prev == 0): heads[b] = cw[1]
			else: prev[1] = cw[1]
			block = cur
			cur = 0
		else:
			misses = misses + 1
			prev = cw
			cur = cw[1]
	if (block == 0):
		int k = b + 1
		while ((k < th_bin_count) && (block == 0)):
			if (heads[k] != 0):
				block = heads[k]
				int* kw = cast(int*, block)
				heads[k] = kw[1]
			k = k + 1
	if (block == 0):
		# a difference, not a sum: x86 addresses past 2GB are negative
		if (h.end - h.ptr < header + size):
			if (th_heap_grow(h, header + size) == 0): return cast(void*, 0)
		block = h.ptr
		h.ptr = h.ptr + header + size
		int* nw = cast(int*, block)
		nw[0] = size
		nw[1] = 0
		return cast(void*, block + header)
	int* bw = cast(int*, block)
	int have = bw[0]
	if (have >= size + header + 8):
		th_bin_push(h, block + header + size, have - size - header)
		bw[0] = size
	bw[1] = 0
	return cast(void*, block + header)


void th_copy(char* dst, char* src, int n):
	int words = n / __word_size__
	int* dw = cast(int*, dst)
	int* sw = cast(int*, src)
	int i = 0
	while (i < words):
		dw[i] = sw[i]
		i = i + 1
	i = words * __word_size__
	while (i < n):
		dst[i] = src[i]
		i = i + 1


# ---- the lib/memory.w hooks ----

void* th_malloc(int size):
	wheap* h = th_heap
	if ((h == 0) && th_is_worker):
		# the worker's heap could not be mapped at start: retry, and
		# fail the allocation rather than touch the main heap
		h = th_heap_acquire()
		th_heap = h
		if (h == 0): return cast(void*, 0)
	if (h == 0):
		if (th_main_remote != 0): th_main_drain()
		return malloc_backend(size)
	return th_heap_malloc(h, size)


int th_free(void* p):
	if (p == 0): return 0
	int block = cast(int, p) - 2 * __word_size__
	wheap* owner = th_owner(cast(int, p))
	if (owner == 0):
		if (th_is_worker == 0): return malloc_backend_free(p)
		th_remote_push(&th_main_remote, block)
		return 1
	if (owner == th_heap):
		int* bw = cast(int*, block)
		th_bin_push(owner, block, bw[0])
		return 1
	th_remote_push(&owner.remote, block)
	return 1


char* th_realloc(void* old, int oldlen, int newlen):
	if (old == 0): return cast(char*, th_malloc(newlen))
	wheap* owner = th_owner(cast(int, old))
	if ((owner == 0) && (th_is_worker == 0)): return malloc_backend_realloc(old, oldlen, newlen)
	if ((owner != 0) && (owner == th_heap)):
		int* bw = cast(int*, cast(int, old) - 2 * __word_size__)
		if (((newlen + 7) >> 3) << 3 <= bw[0]): return cast(char*, old)
	char* grown = cast(char*, th_malloc(newlen))
	if (grown == 0):
		return grown
	int n = oldlen
	if (n > newlen): n = newlen
	th_copy(grown, cast(char*, old), n)
	th_free(old)
	return grown


# W_DEBUG_ALLOC: one lock around the unchanged backend.
int th_debug_lock

void th_debug_acquire():
	while (atomic_cas(&th_debug_lock, 0, 1) != 0): th_yield()


void th_debug_release():
	atomic_cas(&th_debug_lock, 1, 0)


void* th_locked_malloc(int size):
	th_debug_acquire()
	void* p = malloc_backend(size)
	th_debug_release()
	return p


int th_locked_free(void* p):
	th_debug_acquire()
	int r = malloc_backend_free(p)
	th_debug_release()
	return r


char* th_locked_realloc(void* old, int oldlen, int newlen):
	th_debug_acquire()
	char* r = malloc_backend_realloc(old, oldlen, newlen)
	th_debug_release()
	return r


# Called by thread_spawn before the first clone (main thread, no
# worker exists yet, so the plain stores below race with nothing).
void thread_heap_install():
	if (th_installed): return
	th_installed = 1
	malloc_init_mode()
	if (malloc_debug_mode):
		malloc_hook_set(cast(int, th_locked_malloc), cast(int, th_locked_free), cast(int, th_locked_realloc))
		return
	th_registry = th_mmap(32768 * __word_size__)
	if (th_registry == 0):
		malloc_hook_set(cast(int, th_locked_malloc), cast(int, th_locked_free), cast(int, th_locked_realloc))
		return
	malloc_hook_set(cast(int, th_malloc), cast(int, th_free), cast(int, th_realloc))


# Worker start/exit (lib/thread.w thread_entry). With the debug lock
# hooks installed there is no registry and th_heap stays 0.
void thread_heap_attach():
	if (th_registry != 0):
		th_is_worker = 1
		th_heap = th_heap_acquire()


void thread_heap_detach():
	th_is_worker = 0
	th_heap_release(th_heap)
	th_heap = cast(wheap*, 0)
