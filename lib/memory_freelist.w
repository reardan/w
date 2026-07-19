/*
Free-list heap allocator backend: freelist_malloc, freelist_free and
freelist_realloc.

This is the default production backend, dispatched to by lib/memory.w
(see that file for the malloc/free/realloc entry points and how backends
are selected). Every block has a two-word header: [size][next], 8 bytes
on x86 and 16 on x64. size counts payload bytes only; next links free
blocks (0 ends the list).

Free blocks are filed into size-class bins (an array of free-list heads)
instead of one global list: bins 0..31 hold exact sizes 8..256 in 8-byte
steps, bins 32..39 hold doubling ranges above 256 up to 65536, and the
last bin holds everything larger (see malloc_size_bin). freelist_malloc
first-fits within the request's own bin (neighbours are the same size
class, so the scan stays short and the exact-size bins never miss),
then pops the head of the first non-empty higher bin (guaranteed to
fit, since every block in a higher bin is at least as large as any in
the request's own bin), splitting large blocks; only when every bin
comes up empty does it grow the heap with brk. freelist_free() pushes
blocks onto their size bin in O(1). Picking the numerically-closest
non-empty bin trades strict recency (a single list always reused
whatever was freed most recently) for a closer size fit across classes
-- a smaller long-lived free block can now beat a larger block freed
moments ago. A single first-fit list went quadratic under mixed-size
churn: every large malloc rescanned all the small free blocks
(tests/malloc_churn_test.w is the regression benchmark).

The bin-head array itself is carved out of the bump region on first use,
so the block layout is unchanged and the module needs no static
initializers.

The OS layer (brk and the other syscall wrappers) stays in lib/linux.w;
only the allocation policy lives here, so swapping allocators means
adding another backend module (see lib/memory_debug.w for the
guard-page debug backend) rather than editing this one.
*/
import lib.linux


# bin-head array (malloc_bin_count() words); 0 until first use
int malloc_bins
int malloc_heap_ptr
int malloc_heap_end
int malloc_mmap_mode /* brk growth failed once: chunks come from mmap now */
# free blocks examined by freelist_malloc; scan-cost proxy for tests
int malloc_scan_steps


# Header fields are target words so next holds a full pointer on x64;
# load_int/save_int would truncate it to 4 bytes.
int malloc_load_word(int p):
	int* w = cast(int*, p)
	return w[0]


void malloc_save_word(int p, int v):
	int* w = cast(int*, p)
	w[0] = v


int malloc_bin_count():
	return 41


# Map a payload size (already rounded to a multiple of 8, >= 8) to its
# bin. Bins 0..31 are exact: bin = size/8 - 1 for 8..256. Above that the
# ranges double: bin 32 holds 257..512, bin 33 holds 513..1024, ... bin
# 39 holds 32769..65536; bin 40 holds everything larger. A block in any
# higher bin is therefore always large enough for a request binned lower.
int malloc_size_bin(int size):
	if (size <= 256):
		return (size >> 3) - 1
	int limit = 512
	int b = 32
	while ((size > limit) && (b < 40)):
		limit = limit << 1
		b = b + 1
	return b


# Written directly with write(2), not lib.lib's print2/println2: this
# file backs malloc() for every program (see lib/memory.w's header
# comment on why it must not pull in lib.lib), including the minimal
# fixtures that define their own _main to skip the standard runtime.
void malloc_oom_notice():
	char* msg = c"malloc: out of memory (heap growth failed)\x0a"
	int n = 0
	while (msg[n] != 0):
		n = n + 1
	write(2, msg, n)


# Bump-allocate `needed` raw bytes, growing the heap in 64KB chunks so
# most calls avoid the two brk syscalls the old allocator paid every
# time. Returns the block address, or 0 when the OS refuses more memory.
int malloc_grow(int needed):
	if (malloc_heap_ptr == 0):
		malloc_heap_ptr = brk(0)
		malloc_heap_end = malloc_heap_ptr
	if (malloc_heap_ptr + needed > malloc_heap_end):
		int chunk = 65536
		if (needed > chunk):
			chunk = ((needed + 65535) >> 16) << 16
		# brk reports failure by returning the old break, never a negative
		# errno. Growth can fail when a mapping sits right above the heap
		# (e.g. the repl/wdbg MAP_32BIT code buffer next to a
		# low-randomized brk base), so compare the result with the request
		# (equality: high mmap addresses look negative to signed ordering
		# on x86); on failure switch to mmap chunks permanently (a later
		# brk call could otherwise shrink the break below live blocks).
		int grew = 0
		if (malloc_mmap_mode == 0):
			# The program break may be shared with another allocator:
			# dynamically linked programs (c_lib) pull in glibc, whose
			# malloc also grows the break. If it moved since our last
			# growth, extending from the stale end would shrink the break
			# and unmap the other allocator's live heap. Hand the break
			# over and use mmap chunks from now on.
			if (brk(0) != malloc_heap_end):
				malloc_mmap_mode = 1
			else:
				int target = malloc_heap_end + chunk
				if (brk(cast(char*, target)) == target):
					grew = 1
		if (grew):
			malloc_heap_end = malloc_heap_end + chunk
		else:
			malloc_mmap_mode = 1
			# MAP_32BIT on x64 keeps malloc'd memory addressable by
			# 32-bit immediates, which the in-process repl/wdbg
			# expression eval relies on
			int flags = 34 /* PRIVATE|ANONYMOUS */
			if (__word_size__ == 8):
				flags = flags + 64
			int fresh = mmap(0, chunk, 3, flags)
			if ((fresh < 0) && (fresh > -4096)):
				malloc_oom_notice()
				return 0
			malloc_heap_ptr = fresh
			malloc_heap_end = fresh + chunk
	int block = malloc_heap_ptr
	malloc_heap_ptr = malloc_heap_ptr + needed
	return block


# Carve the bin-head array out of the bump region the first time the
# allocator runs (W has no static initializers). freelist_malloc always
# bumps by a multiple of 8 so payloads stay 8-byte aligned relative to
# the heap's (8-aligned) starting break; round this raw malloc_grow call
# the same way, since malloc_bin_count() * __word_size__ is not itself
# a multiple of 8 on 32-bit targets (41 * 4 = 164).
void malloc_bins_init():
	if (malloc_bins != 0):
		return
	int bytes = malloc_bin_count() * __word_size__
	bytes = ((bytes + 7) >> 3) << 3
	int base = malloc_grow(bytes)
	if (base == 0):
		return
	int i = 0
	while (i < malloc_bin_count()):
		malloc_save_word(base + i * __word_size__, 0)
		i = i + 1
	malloc_bins = base


# File a free block of `size` payload bytes into its size bin.
void malloc_bin_push(int block, int size):
	malloc_save_word(block, size)
	int head = malloc_bins + malloc_size_bin(size) * __word_size__
	malloc_save_word(block + __word_size__, malloc_load_word(head))
	malloc_save_word(head, block)


void* freelist_malloc(int size):
	if (size < 1):
		size = 1
	# Round up to 8 bytes so blocks stay aligned
	size = ((size + 7) >> 3) << 3

	int header = 2 * __word_size__

	malloc_bins_init()
	if (malloc_bins == 0):
		return cast(void*, 0)

	# First fit within the request's own bin. Exact bins always fit on
	# the first block; a range bin can hold blocks slightly smaller than
	# the request, so cap the misses at 16 — past that, take a
	# guaranteed-fit block from a higher bin (or fresh memory) instead of
	# rescanning the same too-small blocks, keeping malloc O(1). Skipped
	# blocks stay filed for smaller requests.
	int b = malloc_size_bin(size)
	int head = malloc_bins + b * __word_size__
	int block = 0
	int prev = 0
	int misses = 0
	int cur = malloc_load_word(head)
	while ((cur != 0) && (misses < 16)):
		malloc_scan_steps = malloc_scan_steps + 1
		if (malloc_load_word(cur) >= size):
			int next = malloc_load_word(cur + __word_size__)
			if (prev == 0):
				malloc_save_word(head, next)
			else:
				malloc_save_word(prev + __word_size__, next)
			block = cur
			cur = 0
		else:
			misses = misses + 1
			prev = cur
			cur = malloc_load_word(cur + __word_size__)

	# Any block in a higher bin fits by construction: pop the first one.
	int k = b + 1
	while ((block == 0) & (k < malloc_bin_count())):
		head = malloc_bins + k * __word_size__
		cur = malloc_load_word(head)
		if (cur != 0):
			malloc_scan_steps = malloc_scan_steps + 1
			malloc_save_word(head, malloc_load_word(cur + __word_size__))
			block = cur
		k = k + 1

	if (block == 0):
		# Nothing to reuse: bump-allocate a fresh block.
		block = malloc_grow(size + header)
		if (block == 0):
			return cast(void*, 0)
		malloc_save_word(block, size)
		return block + header

	# Split when the remainder can hold a header and a payload; the
	# remainder is filed back into its own bin.
	int block_size = malloc_load_word(block)
	if (block_size >= size + header + 8):
		malloc_bin_push(block + header + size, block_size - size - header)
		malloc_save_word(block, size)
	return block + header


# Push the block back onto its size bin.
int freelist_free(void* mem_address):
	if (mem_address == 0):
		return 0
	if (malloc_bins == 0):
		return 0
	int block = cast(int, mem_address) - 2 * __word_size__
	malloc_bin_push(block, malloc_load_word(block))
	return 1


# void* accepts any single-level pointer implicitly; word-typed callers
# cast. The copy loop indexes through char* because void has no size.
char *freelist_realloc(void* old, int oldlen, int newlen):
	char *grown = freelist_malloc(newlen)
	char *src = old
	int i = 0
	while (i < oldlen):
		grown[i] = src[i]
		i = i + 1

	freelist_free(old)
	return grown
