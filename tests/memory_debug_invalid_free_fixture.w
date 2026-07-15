# Runtime fixture: freeing a pointer the debug allocator never returned
# (here, a stack address) must be caught and reported, not treated as a
# valid block.
import lib.memory


int main():
	malloc_force_debug_mode()
	int stack_var = 0
	free(&stack_var)
	return 0
