# Inject OS-operation failures through recorded mapping metadata. This
# avoids host-specific resource limits and verifies no silent downgrade.
import lib.lib


int main(int argc, char** argv):
	if (argc != 2): return 2
	malloc_force_debug_mode()
	char* p = cast(char*, malloc(13))
	int idx = debug_tbl_find(cast(int, p))
	if (strcmp(argv[1], c"protect") == 0):
		# The payload and canaries remain intact; an unaligned region
		# makes mprotect fail before it can remove access.
		debug_tbl_region[idx] = debug_tbl_region[idx] + 1
		free(p)
	elif (strcmp(argv[1], c"release") == 0):
		free(p)
		debug_tbl_region[idx] = debug_tbl_region[idx] + 1
		debug_quarantine_reclaim_to(0)
	elif (strcmp(argv[1], c"sequence") == 0):
		debug_alloc_sequence = ~cast(int, 0) ^ (1 << (__word_size__ * 8 - 1))
		malloc(1)
	else: return 2
	return 0
