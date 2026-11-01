# Exhaust virtual address space without consuming physical memory, then grow
# the provenance table from an allocation served by an existing free block.
import lib.thread_heap


void provenance_exhaust_mappings(int bytes):
	while (1):
		int address = mmap(0, bytes, 0, 34)
		if ((address < 0) && (address > -4096)): return


int main(int argc, char** argv):
	malloc_provenance_enabled = 1
	if (argc > 1): thread_heap_install()
	void* spare = malloc(131072)
	if (spare == 0): return 2
	free(spare)
	while (malloc_provenance_used * 2 < malloc_provenance_capacity):
		if (malloc(8) == 0): return 3

	# Native struct rlimit, RLIMIT_AS = 9. setrlimit is syscall 75 on
	# Linux x86 and 160 on x64. This bounds the reservation loop to 64 MiB.
	int[2] limit
	limit[0] = 64 * 1024 * 1024
	limit[1] = limit[0]
	int number = 75
	if (__word_size__ == 8): number = 160
	if (syscall7(number, 9, cast(int, &limit[0]), 0, 0, 0, 0) != 0): return 4
	provenance_exhaust_mappings(1024 * 1024)
	provenance_exhaust_mappings(4096)

	# The free list has room, but the next provenance insertion must grow.
	# A stack trace here would recursively allocate while the table is full;
	# with the thread hooks installed it would also reacquire the held lock.
	malloc(8)
	return 5
