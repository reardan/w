# wbuild: x64
# wbuild: step="bin/malloc_host_mode_test host" env="W_DEBUG_ALLOC=1" expect_stdout="host keeps the free list"
# wbuild: step="bin/malloc_host_mode_test late" env="W_DEBUG_ALLOC=1" expect_stdout="debug mode already fixed"
# malloc_host_freelist_mode (lib/memory.w): an in-process host (the REPL,
# wdbg) keeps the free-list backend under W_DEBUG_ALLOC when it asks before
# its first allocation, so the variable only selects the session image's
# allocator; asked after debug mode is fixed, it reports that and changes
# nothing. Without arguments (the plain test run) both cases run unset.
import lib.lib


int main(int argc, char** argv):
	if (argc < 2):
		if (malloc_host_freelist_mode() != 1): return 1
		if (malloc_host_freelist_mode() != 1): return 2
		return 0
	if (strcmp(argv[1], c"host") == 0):
		if (malloc_host_freelist_mode() != 1): return 3
		char* block = cast(char*, malloc(24))
		if (malloc_debug_mode != 0): return 4
		if (debug_tbl_count != 0): return 5
		free(block)
		println(c"host keeps the free list")
		return 0
	char* first = cast(char*, malloc(24))
	if (malloc_debug_mode != 1): return 6
	if (malloc_host_freelist_mode() != 0): return 7
	if (malloc_debug_mode != 1): return 8
	free(first)
	println(c"debug mode already fixed")
	return 0
