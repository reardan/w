# Runtime fixture: touching memory after free() must fault (SIGSEGV) in
# debug mode, since free() protects the whole region PROT_NONE rather
# than returning it for reuse.
import lib.memory


int main():
	malloc_force_debug_mode()
	char* a = malloc(10)
	free(a)
	a[0] = 1
	return 0
