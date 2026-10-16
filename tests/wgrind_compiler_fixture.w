# Compiler-assisted cases. No checker calls occur in the source: heap,
# local and source events are inserted by --wgrind. _main keeps startup
# small enough to exercise the execution engine independently of lib.lib.
import lib.linux


void* unchecked_allocator(int size):
	write(1, c"unchecked callback", 18)
	return freelist_malloc(size)


int _main(int argc, char** argv):
	if (argc < 2): return 2
	int mode = argv[1][0]
	if (mode == 'h'): malloc_hook_set(cast(int, unchecked_allocator), 0, 0)
	if (mode == 'H'): malloc_hook_malloc = cast(int, unchecked_allocator)
	char* p = cast(char*, malloc(8))
	if (mode == 'c'):
		p[0] = 7
		if (p[0] != 7): return 3
	elif (mode == 'u'):
		if (p[0] == 42): return 3
	elif (mode == 's'):
		int local
		if (local == 42): return 3
	elif (mode == 'o'):
		p[8] = 1
	elif (mode == 'b'):
		p[-1] = 1
	elif (mode == 'f'):
		free(p)
		p[0] = 1
		return 0
	elif (mode == 'd'):
		free(p)
		free(p)
		return 0
	elif (mode == 'm'):
		int masked = p[0] & 0
		if (masked != 0): return 3
	elif (mode == 'p'):
		char* other = cast(char*, malloc(8))
		other[0] = p[0]
		free(other)
	elif (mode == 'r'):
		p[0] = 7
		p = realloc(p, 8, 16)
		if (p[8] == 0): return 3
	elif (mode == 'g'):
		p[0] = 7
		p = realloc(p, 8, 16)
		if (p[0] != 7): return 3
		p[8] = 1
	elif (mode == 'z'):
		free(p)
		p = cast(char*, malloc(0))
		p[0] = 7
		p = realloc(p, 1, 0)
		if (p[0] != 7): return 3
	elif ((mode == 'j') || (mode == 'k')):
		for i in range(8): p[i] = 42
		char* blocker = cast(char*, malloc(8))
		# The live blocker forces a move. W's oldlen is the used prefix,
		# so only four bytes are copied even though eight were allocated.
		p = realloc(p, 4, 4096)
		if (mode == 'j'):
			if (p[4] == 42): return 3
		else:
			if (p[3] != 42): return 3
		free(blocker)
	free(p)
	return 0
