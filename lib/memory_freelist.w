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
comes up empty does it grow the heap with brk. A two-word bitmap of
non-empty bins (malloc_bin_map_lo/hi) finds that higher bin in a few
bit operations instead of probing all 41 heads; it is kept exact by
malloc_bin_push and every pop, so a set bit always means a non-empty
bin. freelist_free() pushes
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

The heap grows geometrically (a quarter of what it already holds,
between 64 KB and 4 MB per step) so allocation-heavy programs pay a
handful of brk calls instead of thousands. freelist_realloc returns the
block unchanged when its payload already fits, extends the most recent
bump allocation in place, and otherwise copies word by word.

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
# Non-empty-bin bitmap: bit b of _lo is bin b (0..20), bit b-21 of _hi
# is bin b (21..40). 21/20 bits per word keep bit 31 (the sign bit on
# 32-bit targets) clear, so plain >> never smears a sign.
int malloc_bin_map_lo
int malloc_bin_map_hi
# bytes obtained from the OS so far; sizes the next growth step
int malloc_heap_total


const int malloc_bin_count = 41


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


# File a free block of `size` payload bytes into its size bin.
void malloc_bin_push(int block, int size):
	int b = malloc_size_bin(size)
	int* heads = cast(int*, malloc_bins)
	int* w = cast(int*, block)
	w[0] = size
	w[1] = heads[b]
	heads[b] = block
	if (b < 21):
		malloc_bin_map_lo = malloc_bin_map_lo | (1 << b)
	else:
		malloc_bin_map_hi = malloc_bin_map_hi | (1 << (b - 21))


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


# Make room for `needed` more bump bytes: afterwards malloc_heap_ptr +
# needed <= malloc_heap_end. Growth is geometric -- a quarter of the heap
# obtained so far, clamped to 64 KB..4 MB, or more when one request needs
# it -- so the brk syscalls stay logarithmic-then-linear in heap size
# instead of two per 64 KB. malloc_heap_ptr moves only when growth has to
# start a fresh mmap chunk (the old chunk's tail is filed as a free block
# first). Returns 0 when the OS refuses more memory.
int malloc_heap_extend(int needed):
	int chunk = malloc_heap_total >> 2
	if (chunk > 4194304):
		chunk = 4194304
	if (chunk < 65536):
		chunk = 65536
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
		# Recycle the abandoned tail of the previous chunk (always a
		# multiple of 8) rather than leaking it.
		int header = 2 * __word_size__
		int tail = malloc_heap_end - malloc_heap_ptr
		if ((malloc_bins != 0) && (malloc_heap_ptr != 0) && (tail >= header + 8)):
			malloc_bin_push(malloc_heap_ptr, tail - header)
		malloc_heap_ptr = fresh
		malloc_heap_end = fresh + chunk
	malloc_heap_total = malloc_heap_total + chunk
	return 1


# Bump-allocate `needed` raw bytes, growing the heap when the current
# chunk runs out. Returns the block address, or 0 when the OS refuses
# more memory.
int malloc_grow(int needed):
	if (malloc_heap_ptr == 0):
		malloc_heap_ptr = brk(0)
		malloc_heap_end = malloc_heap_ptr
	if (malloc_heap_ptr + needed > malloc_heap_end):
		if (malloc_heap_extend(needed) == 0):
			return 0
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
	int bytes = malloc_bin_count * __word_size__
	bytes = ((bytes + 7) >> 3) << 3
	int base = malloc_grow(bytes)
	if (base == 0):
		return
	int* heads = cast(int*, base)
	int i = 0
	while (i < malloc_bin_count):
		heads[i] = 0
		i = i + 1
	malloc_bin_map_lo = 0
	malloc_bin_map_hi = 0
	malloc_bins = base


# Index of the lowest set bit of a nonzero mask.
int malloc_low_bit(int m):
	int i = 0
	if ((m & 1023) == 0):
		m = m >> 10
		i = 10
	if ((m & 31) == 0):
		m = m >> 5
		i = i + 5
	while ((m & 1) == 0):
		m = m >> 1
		i = i + 1
	return i


# Lowest non-empty bin above `b`, or -1 when there is none.
int malloc_next_bin(int b):
	int k = b + 1
	if (k < 21):
		int lo = malloc_bin_map_lo >> k
		if (lo != 0):
			return k + malloc_low_bit(lo)
		k = 21
	if (k > 40):
		return -1
	int hi = malloc_bin_map_hi >> (k - 21)
	if (hi == 0):
		return -1
	return k + malloc_low_bit(hi)


# Clear bin b's bit once its list has become empty.
void malloc_bin_clear(int b):
	if (b < 21):
		malloc_bin_map_lo = malloc_bin_map_lo ^ (1 << b)
	else:
		malloc_bin_map_hi = malloc_bin_map_hi ^ (1 << (b - 21))


void* freelist_malloc(int size):
	if (size < 1):
		size = 1
	# Round up to 8 bytes so blocks stay aligned
	size = ((size + 7) >> 3) << 3

	int header = 2 * __word_size__

	if (malloc_bins == 0):
		malloc_bins_init()
		if (malloc_bins == 0):
			return cast(void*, 0)
	int* heads = cast(int*, malloc_bins)

	# First fit within the request's own bin. Exact bins always fit on
	# the first block; a range bin can hold blocks slightly smaller than
	# the request, so cap the misses at 16 — past that, take a
	# guaranteed-fit block from a higher bin (or fresh memory) instead of
	# rescanning the same too-small blocks, keeping malloc O(1). Skipped
	# blocks stay filed for smaller requests.
	int b = malloc_size_bin(size)
	int block = 0
	int cur = heads[b]
	if (cur != 0):
		int* prev = cast(int*, 0)
		int misses = 0
		while ((cur != 0) && (misses < 16)):
			malloc_scan_steps = malloc_scan_steps + 1
			int* cw = cast(int*, cur)
			if (cw[0] >= size):
				if (prev == 0):
					heads[b] = cw[1]
				else:
					prev[1] = cw[1]
				block = cur
				cur = 0
			else:
				misses = misses + 1
				prev = cw
				cur = cw[1]
		if ((block != 0) && (heads[b] == 0)):
			malloc_bin_clear(b)

	# Any block in a higher bin fits by construction: pop the head of
	# the lowest non-empty one.
	if (block == 0):
		int k = malloc_next_bin(b)
		if (k >= 0):
			malloc_scan_steps = malloc_scan_steps + 1
			block = heads[k]
			int* kw = cast(int*, block)
			heads[k] = kw[1]
			if (kw[1] == 0):
				malloc_bin_clear(k)

	int* bw = cast(int*, block)
	if (block == 0):
		# Nothing to reuse: bump-allocate a fresh block.
		int top = malloc_heap_ptr
		if (top + size + header <= malloc_heap_end):
			malloc_heap_ptr = top + size + header
			block = top
		else:
			block = malloc_grow(size + header)
			if (block == 0):
				return cast(void*, 0)
		bw = cast(int*, block)
		bw[0] = size
		return block + header

	# Split when the remainder can hold a header and a payload; the
	# remainder is filed back into its own bin.
	int block_size = bw[0]
	if (block_size >= size + header + 8):
		malloc_bin_push(block + header + size, block_size - size - header)
		bw[0] = size
	return block + header


# Push the block back onto its size bin.
int freelist_free(void* mem_address):
	if (mem_address == 0):
		return 0
	if (malloc_bins == 0):
		return 0
	int block = cast(int, mem_address) - 2 * __word_size__
	int* bw = cast(int*, block)
	malloc_bin_push(block, bw[0])
	return 1


# Callers pass the old allocation size as oldlen (see
# structures/string.w); the block header's own payload size decides the
# fast paths. A block whose payload already holds newlen comes back
# unchanged; the most recent bump allocation grows in place; anything
# else moves, copying min(oldlen, newlen) bytes a word at a time
# (payloads are 8-aligned).
char *freelist_realloc(void* old, int oldlen, int newlen):
	if (old == 0):
		return freelist_malloc(newlen)
	int header = 2 * __word_size__
	int mem = cast(int, old)
	int* bw = cast(int*, mem - header)
	int have = bw[0]
	int want = newlen
	if (want < 1):
		want = 1
	want = ((want + 7) >> 3) << 3
	if (want <= have):
		return old
	if (mem + have == malloc_heap_ptr):
		int extra = want - have
		int fits = 0
		if (malloc_heap_ptr + extra <= malloc_heap_end):
			fits = 1
		else:
			# brk growth keeps the top contiguous; an mmap chunk switch
			# moves malloc_heap_ptr and we fall through to a copy.
			if (malloc_heap_extend(extra)):
				if (mem + have == malloc_heap_ptr):
					fits = 1
		if (fits):
			malloc_heap_ptr = malloc_heap_ptr + extra
			bw[0] = want
			return old
	char *grown = freelist_malloc(newlen)
	if (grown == 0):
		return grown
	int n = oldlen
	if (n > newlen):
		n = newlen
	int* dw = cast(int*, grown)
	int* sw = cast(int*, old)
	int words = n / __word_size__
	int i = 0
	while (i < words):
		dw[i] = sw[i]
		i = i + 1
	char *src = old
	i = words * __word_size__
	while (i < n):
		grown[i] = src[i]
		i = i + 1

	freelist_free(old)
	return grown
