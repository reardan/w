/*
Heap allocator: malloc, free and realloc.

Free-list allocator. Every block has an 8-byte header: [size][next]. size
counts payload bytes only; next links free blocks (0 ends the list).
malloc searches the free list first (first fit, splitting large blocks)
and only grows the heap with brk when nothing fits. free() pushes blocks
back onto the list.

The OS layer (brk and the other syscall wrappers) stays in lib/linux.w;
only the allocation policy lives here, so swapping allocators means
swapping this module.
*/
import lib.linux


int malloc_free_list
int malloc_heap_ptr
int malloc_heap_end


void* malloc(int size):
	if (size < 1):
		size = 1
	# Round up to 8 bytes so blocks stay aligned
	size = ((size + 7) >> 3) << 3

	# First fit from the free list
	int prev = 0
	int block = malloc_free_list
	while (block != 0):
		int block_size = load_int(cast(char*, block))
		if (block_size >= size):
			int next = load_int(block + 4)
			# Split when the remainder can hold a header and a payload
			if (block_size >= size + 16):
				int rest = block + 8 + size
				save_int(cast(char*, rest), block_size - size - 8)
				save_int(rest + 4, next)
				next = rest
				save_int(cast(char*, block), size)
			if (prev == 0):
				malloc_free_list = next
			else:
				save_int(prev + 4, next)
			return block + 8
		prev = block
		block = load_int(block + 4)

	# Nothing fits: bump-allocate, growing the heap in 64KB chunks so most
	# mallocs avoid the two brk syscalls the old allocator paid every time.
	int needed = size + 8
	if (malloc_heap_ptr == 0):
		malloc_heap_ptr = brk(0)
		malloc_heap_end = malloc_heap_ptr
	if (malloc_heap_ptr + needed > malloc_heap_end):
		int chunk = 65536
		if (needed > chunk):
			chunk = ((needed + 65535) >> 16) << 16
		int err = brk(malloc_heap_end + chunk)
		if (err < 0):
			return cast(void*, err)
		malloc_heap_end = malloc_heap_end + chunk

	block = malloc_heap_ptr
	malloc_heap_ptr = malloc_heap_ptr + needed
	save_int(cast(char*, block), size)
	return block + 8


# Push the block back onto the allocator's free list.
int free(void* mem_address):
	if (mem_address == 0):
		return 0
	int block = mem_address - 8
	save_int(block + 4, malloc_free_list)
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
