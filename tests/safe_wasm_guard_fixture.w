# wbuild: target=safe_wasm_guard_test tag=tests_wasm dep=wv2 dep=wrun
# wbuild: step="bin/wv2 wasm --strict tests/safe_wasm_guard_fixture.w -o bin/safe_wasm_guard_fixture"
# wbuild: step="bin/wrun wasm bin/safe_wasm_guard_fixture" expect_stdout="wasm guard substitute ok"
# wbuild: step="bin/wrun wasm bin/safe_wasm_guard_fixture overflow" expect_fail expect_stderr="memory_debug: heap buffer overflow"
# wbuild: step="bin/wrun wasm bin/safe_wasm_guard_fixture slack" expect_fail expect_stderr="memory_debug: heap buffer overflow"
# wbuild: step="bin/wrun wasm bin/safe_wasm_guard_fixture underflow" expect_fail expect_stderr="memory_debug: heap buffer underflow"
# wbuild: step="bin/wrun wasm bin/safe_wasm_guard_fixture use_after_free" expect_fail expect_stderr="memory_debug: heap use after free"
# wbuild: step="bin/wrun wasm bin/safe_wasm_guard_fixture double_free" expect_fail expect_stderr="memory_debug: double free() detected"
# wbuild: step="bin/wrun wasm bin/safe_wasm_guard_fixture bounds" expect_fail expect_stderr="index out of range: index 2, length 2"
#
# wasm32 linear memory cannot unmap or protect pages, so the guard
# allocator's wasm substitute (lib/memory_debug.w) keeps the guard page
# resident as canaries and poisons freed payloads; faults become checks at
# free, realloc and leak-report time. With no argument this runs the
# in-process checks, including checked-owner cleanup accounting; each
# named scenario is a separate run whose expected death the steps assert.
import lib.lib
import lib.memory


own int* guard_make(int value):
	own int* p = new int
	*p = value
	return p


int guard_consume(own int* p):
	return *p


# Owners released on every exit leave the debug allocator's live count
# unchanged; the moved owner is released by its callee.
int guard_checked_cleanup(int choice):
	own int* kept = guard_make(3)
	own int* moved = guard_make(4)
	if (choice == 1): return guard_consume(moved)
	int total = *kept + guard_consume(moved)
	return total


int guard_checked_index(ref int[] values, int index):
	return values[index]


# Checked indexing past the descriptor's length traps on wasm too.
int guard_bounds(int index):
	int[2] values
	return guard_checked_index(values, index)


int guard_in_process():
	int before = debug_alloc_report_leaks()
	if (guard_checked_cleanup(0) != 7): return 1
	if (guard_checked_cleanup(1) != 4): return 2
	if (debug_alloc_report_leaks() != before): return 3
	# A freed payload reads back as poison, not as stale data or zeros.
	char* block = cast(char*, malloc(12))
	block[0] = 1
	free(block)
	if ((block[0] & 255) != 107): return 4
	# Bookkeeping still counts a live block as a leak.
	char* live = cast(char*, malloc(5))
	if (debug_alloc_report_leaks() != before + 1): return 5
	free(live)
	if (debug_alloc_report_leaks() != before): return 6
	# The resident guard page holds canaries right after the slack.
	char* small = cast(char*, malloc(8))
	if ((small[8] & 255) != 90): return 7
	if ((small[4095 + 8] & 255) != 90): return 8
	free(small)
	# realloc copies the payload, then poisons the block it replaced.
	char* old = cast(char*, malloc(3))
	old[0] = 5
	char* grown = realloc(old, 3, 40)
	if (grown[0] != 5): return 9
	if ((old[0] & 255) != 107): return 10
	free(grown)
	if (debug_alloc_report_leaks() != before): return 11
	return 0


int main(int argc, int argv):
	malloc_force_debug_mode()
	char** args = cast(char**, argv)
	if (argc < 2):
		int failed = guard_in_process()
		if (failed): return failed
		println(c"wasm guard substitute ok")
		return 0
	char* mode = args[1]
	char* p = cast(char*, malloc(8))
	if (strcmp(mode, c"overflow") == 0):
		p[100] = 1
		free(p)
	if (strcmp(mode, c"slack") == 0):
		char* q = cast(char*, malloc(5))
		q[6] = 1
		free(q)
	if (strcmp(mode, c"underflow") == 0):
		p[0 - 3] = 1
		free(p)
	if (strcmp(mode, c"use_after_free") == 0):
		free(p)
		p[2] = 1
		debug_alloc_report_leaks()
	if (strcmp(mode, c"double_free") == 0):
		free(p)
		free(p)
	if (strcmp(mode, c"bounds") == 0):
		return guard_bounds(argc)
	return 0
