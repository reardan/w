# Runtime fixture: writing one byte past a debug-mode allocation must
# fault on its trailing guard page (SIGSEGV), not silently corrupt
# whatever memory happens to follow it.
import lib.memory


int main():
	malloc_force_debug_mode()
	char* a = malloc(10)
	a[10] = 1
	return 0
