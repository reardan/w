# wbuild: x64 arch=wasm
# Heap growth in mmap mode keeps every block boundary 8-aligned.
#
# lib/memory_freelist.w grows the heap by a quarter of what it already
# holds. Once that quarter stopped being a multiple of 8 (past ~1.25 MB),
# malloc_heap_end ended up 4 bytes off the 8-aligned bump pointer. With
# brk the heap stays contiguous and nothing noticed, but in mmap mode --
# always on wasm and arm64_darwin, and the repl/wdbg fallback when brk
# growth is blocked -- the old chunk's tail was filed as a free block
# whose size was not a multiple of 8. The block (or a split remainder)
# was later handed to some caller and its free() died with
# "free(): invalid pointer (not a heap block)": the AST front end's
# intermittent crash in the 64-bit in-process compiler, and an every-time
# crash of a wasm-hosted compiler in AST mode.
#
# The test forces mmap mode, grows the heap through many geometric steps
# and checks the allocator's invariants after every growth, then churns
# the free lists so any malformed block reaches free().
import lib.lib
import lib.assert
import lib.memory_freelist


int lcg_state


int lcg_next():
	lcg_state = (lcg_state * 1103515245 + 12345) & 0x7fffffff
	return lcg_state


# Free blocks whose recorded size no freelist_malloc block can have.
int malformed_free_blocks():
	if (malloc_bins == 0): return 0
	int* heads = cast(int*, malloc_bins)
	int bad = 0
	for b in range(malloc_bin_count):
		int cur = heads[b]
		while (cur != 0):
			int* words = cast(int*, cur)
			if ((words[0] <= 0) || ((words[0] & 7) != 0)): bad = bad + 1
			cur = words[1]
	return bad


int main():
	malloc_mmap_mode = 1
	int count = 6000
	int** blocks = cast(int**, malloc(count * __word_size__))
	int growths = 0
	int end = malloc_heap_end
	for i in range(count):
		# Odd sizes leave tails of every length at each chunk switch.
		blocks[i] = cast(int*, malloc(1000 + (i % 7) * 360))
		blocks[i][0] = i
		if (malloc_heap_end != end):
			growths = growths + 1
			end = malloc_heap_end
			assert_equal(0, malloc_heap_end & 7)
			assert_equal(0, malloc_heap_ptr & 7)
			assert_equal(0, malformed_free_blocks())
	assert1(growths >= 12)
	assert1(malloc_heap_total >= 8388608)
	# Churn: hand the recycled chunk tails back out and free them again.
	lcg_state = 7
	for round in range(4):
		for i in range(count):
			if ((lcg_next() & 1) == 0):
				assert_equal(i, blocks[i][0])
				free(blocks[i])
				blocks[i] = cast(int*, malloc(8 + (lcg_next() % 4096)))
				blocks[i][0] = i
	assert_equal(0, malformed_free_blocks())
	for i in range(count):
		assert_equal(i, blocks[i][0])
		free(blocks[i])
	free(cast(void*, blocks))
	println(c"malloc_mmap_growth_test OK")
	return 0
