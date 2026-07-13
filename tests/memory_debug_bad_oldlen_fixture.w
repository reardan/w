# Runtime fixture: realloc()'s oldlen argument is trusted by the
# free-list backend, but the debug backend has the real tracked size on
# hand and asserts the caller's oldlen agrees with it.
import lib.memory


int main():
	malloc_force_debug_mode()
	char* a = malloc(10)
	realloc(a, 999, 20)
	return 0
