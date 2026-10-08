# Runtime fixture: writing one byte past a debug-mode allocation must
# fault on its trailing guard page (SIGSEGV), not silently corrupt
# whatever memory happens to follow it. The size is a multiple of 8, so
# the payload ends flush against the guard (smaller overruns into the
# alignment slack of other sizes are caught at free() by the canary,
# tests/alloc_safety_test.w debug_slack).
import lib.memory


int main():
	malloc_force_debug_mode()
	char* a = cast(char*, malloc(16))
	a[16] = 1
	return 0
