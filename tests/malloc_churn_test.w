# Mixed-size alloc/free churn regression benchmark for lib/memory.w.
#
# Workload per round: allocate n small blocks and free them all, so the
# allocator holds n small free blocks, then allocate n larger blocks
# (which no small block can satisfy) and free those too. The old single
# first-fit free list rescanned every small block on every large malloc
# (n*n block visits — quadratic churn, seconds of wall time by
# n=16000). Size-class bins keep small blocks off a large request's
# scan path and cap per-malloc scan work, so the visit count stays
# linear in the number of allocations.
#
# The assertions use malloc_scan_steps (lib/memory.w), which counts free
# blocks examined by malloc — a deterministic scan-cost proxy that does
# not flake under load the way wall-clock timing would. The quadratic
# allocator visits ~n*n blocks per round; the binned allocator's cap
# (16 misses + 1 hit per malloc) bounds a round's 2n mallocs well under
# 40*n visits.
#
# The mixed churn phase reuses, splits and re-files blocks of many size
# classes while verifying block contents, so bin bookkeeping bugs
# (wrong bin, bad unlink, bad split) corrupt data the test notices.
# wbuild: x64
import lib.lib
import lib.assert
import lib.time


int lcg_state


# Deterministic PRNG. The multiply wraps mod 2^32 on x86 and not on
# x64, but the 31-bit mask makes both reduce to the product mod 2^31,
# so every target sees the same sequence (bit 31 stays clear).
int lcg_next():
	lcg_state = (lcg_state * 1103515245 + 12345) & 0x7fffffff
	return lcg_state


# One churn round; returns the free blocks malloc examined during it.
int churn_round(int n, int small_size, int large_size):
	int steps0 = malloc_scan_steps
	int* smalls = malloc(n * __word_size__)
	int i = 0
	while (i < n):
		smalls[i] = cast(int, malloc(small_size))
		i = i + 1
	i = 0
	while (i < n):
		free(cast(void*, smalls[i]))
		i = i + 1
	int* larges = malloc(n * __word_size__)
	i = 0
	while (i < n):
		larges[i] = cast(int, malloc(large_size))
		i = i + 1
	i = 0
	while (i < n):
		free(cast(void*, larges[i]))
		i = i + 1
	free(larges)
	free(smalls)
	return malloc_scan_steps - steps0


void report_round(int n, int steps, int ms):
	print2(c"churn n=")
	print2(itoa(n))
	print2(c" scan_steps=")
	print2(itoa(steps))
	print2(c" ms=")
	println2(itoa(ms))


# Random mixed-size churn with content verification: K slots hold live
# blocks; each op frees or allocates a random slot with a random size
# and a slot-tagged byte pattern, catching cross-block corruption from
# bad bin bookkeeping.
void mixed_churn(int slots, int ops):
	int* ptrs = malloc(slots * __word_size__)
	int* sizes = malloc(slots * __word_size__)
	int* tags = malloc(slots * __word_size__)
	int i = 0
	while (i < slots):
		ptrs[i] = 0
		i = i + 1
	int op = 0
	while (op < ops):
		int slot = lcg_next() % slots
		if (ptrs[slot] != 0):
			char* p = cast(char*, ptrs[slot])
			int j = 0
			while (j < sizes[slot]):
				assert_equal((tags[slot] + j) & 255, p[j] & 255)
				j = j + 1
			free(p)
			ptrs[slot] = 0
		else:
			# Mostly small blocks, every eighth op a large one: keeps
			# many size classes live at once.
			int size = 8 + lcg_next() % 200
			if ((op & 7) == 0):
				size = 1024 + lcg_next() % 4096
			char* fresh = malloc(size)
			int tag = lcg_next() & 255
			int j = 0
			while (j < size):
				fresh[j] = (tag + j) & 255
				j = j + 1
			ptrs[slot] = cast(int, fresh)
			sizes[slot] = size
			tags[slot] = tag
		op = op + 1
	# Verify and release the survivors.
	i = 0
	while (i < slots):
		if (ptrs[i] != 0):
			char* p = cast(char*, ptrs[i])
			int j = 0
			while (j < sizes[i]):
				assert_equal((tags[i] + j) & 255, p[j] & 255)
				j = j + 1
			free(p)
			ptrs[i] = 0
		i = i + 1
	free(tags)
	free(sizes)
	free(ptrs)


void realloc_smoke():
	char* p = malloc(24)
	int i = 0
	while (i < 24):
		p[i] = i + 1
		i = i + 1
	p = realloc(p, 24, 4096)
	i = 0
	while (i < 24):
		assert_equal(i + 1, p[i])
		i = i + 1
	# realloc copies oldlen bytes, so it only grows; regrow across a
	# size-class boundary and recheck the prefix.
	p = realloc(p, 4096, 8192)
	i = 0
	while (i < 24):
		assert_equal(i + 1, p[i])
		i = i + 1
	free(p)


int main(int argc, int argv):
	lcg_state = 42

	# Two problem sizes: with first-fit these rounds cost ~n*n block
	# visits each (4M and 16M); the binned allocator stays linear, so
	# 40*n leaves room for the 16-miss scan cap plus splinter noise
	# while sitting orders of magnitude below quadratic.
	int t0 = time_monotonic_ms()
	int steps1 = churn_round(2000, 24, 4096)
	int t1 = time_monotonic_ms()
	int steps2 = churn_round(4000, 24, 4096)
	int t2 = time_monotonic_ms()
	report_round(2000, steps1, t1 - t0)
	report_round(4000, steps2, t2 - t1)
	asserts(c"mixed-size churn (n=2000) must not scan superlinearly", steps1 < 2000 * 40)
	asserts(c"mixed-size churn (n=4000) must not scan superlinearly", steps2 < 4000 * 40)

	mixed_churn(64, 20000)
	realloc_smoke()

	println2(c"malloc_churn_test passed")
	return 0
