# Runtime fixture: freeing the same pointer twice must be caught and
# reported by the debug allocator's bookkeeping table, not silently
# accepted.
import lib.memory


int main():
	malloc_force_debug_mode()
	char* a = malloc(10)
	free(a)
	free(a)
	return 0
