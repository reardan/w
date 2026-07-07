/*
Heap allocator: malloc, free and realloc.

Free-list allocator. Every block has a two-word header: [size][next],
8 bytes on x86 and 16 on x64. size counts payload bytes only; next links
free blocks (0 ends the list). malloc searches the free list first
(first fit, splitting large blocks) and only grows the heap with brk
when nothing fits. free() pushes blocks back onto the list.

The OS layer (brk and the other syscall wrappers) stays in lib/linux.w;
only the allocation policy lives here, so swapping allocators means
swapping this module.
*/
import lib.linux


int malloc_free_list
int malloc_heap_ptr
int malloc_heap_end
int malloc_mmap_mode /* brk growth failed once: chunks come from mmap now */


# Header fields are target words so next holds a full pointer on x64;
# load_int/save_int would truncate it to 4 bytes.
int malloc_load_word(int p):
	int* w = cast(int*, p)
	return w[0]


void malloc_save_word(int p, int v):
	int* w = cast(int*, p)
	w[0] = v


void* malloc(int size):
	if (size < 1):
		size = 1
	# Round up to 8 bytes so blocks stay aligned
	size = ((size + 7) >> 3) << 3

	int header = 2 * __word_size__

	# First fit from the free list
	int prev = 0
	int block = malloc_free_list
	while (block != 0):
		int block_size = malloc_load_word(block)
		if (block_size >= size):
			int next = malloc_load_word(block + __word_size__)
			# Split when the remainder can hold a header and a payload
			if (block_size >= size + header + 8):
				int rest = block + header + size
				malloc_save_word(rest, block_size - size - header)
				malloc_save_word(rest + __word_size__, next)
				next = rest
				malloc_save_word(block, size)
			if (prev == 0):
				malloc_free_list = next
			else:
				malloc_save_word(prev + __word_size__, next)
			return block + header
		prev = block
		block = malloc_load_word(block + __word_size__)

	# Nothing fits: bump-allocate, growing the heap in 64KB chunks so most
	# mallocs avoid the two brk syscalls the old allocator paid every time.
	int needed = size + header
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
			if ((fresh < 0) & (fresh > -4096)):
				return cast(void*, 0)
			malloc_heap_ptr = fresh
			malloc_heap_end = fresh + chunk

	block = malloc_heap_ptr
	malloc_heap_ptr = malloc_heap_ptr + needed
	malloc_save_word(block, size)
	return block + header


# Push the block back onto the allocator's free list.
int free(void* mem_address):
	if (mem_address == 0):
		return 0
	int block = mem_address - 2 * __word_size__
	malloc_save_word(block + __word_size__, malloc_free_list)
	malloc_free_list = block
	return 1


# void* accepts any single-level pointer implicitly; word-typed callers
# cast. The copy loop indexes through char* because void has no size.
char *realloc(void* old, int oldlen, int newlen):
	char *grown = malloc(newlen)
	char *src = old
	int i = 0
	while (i < oldlen):
		grown[i] = src[i]
		i = i + 1

	free(old)
	return grown
