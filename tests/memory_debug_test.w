# wbuild: x64
# Exercises the guard-page debug allocator (lib/memory_debug.w) through
# the normal malloc/free/realloc entry points, forced on via
# malloc_force_debug_mode() rather than W_DEBUG_ALLOC so the test needs
# no special invocation. Only well-behaved allocation patterns belong
# here -- the fixtures alongside this file cover the fault paths
# (overflow, use-after-free, double free, invalid free, bad realloc
# oldlen), each of which is expected to crash or exit(1).
import lib.lib
import lib.assert
import lib.memory
import structures.string


int main():
	malloc_force_debug_mode()

	char* a = malloc(10)
	int i = 0
	while (i < 10):
		a[i] = 65 + i
		i = i + 1
	asserts(c"payload bytes round-trip", a[0] == 65)
	asserts(c"payload bytes round-trip", a[9] == 74)
	free(a)

	# Growing realloc: contents up to the old size must survive the copy.
	char* b = malloc(8)
	i = 0
	while (i < 8):
		b[i] = 'a' + i
		i = i + 1
	char* grown = realloc(b, 8, 4096)
	i = 0
	while (i < 8):
		asserts(c"realloc preserves contents", grown[i] == 'a' + i)
		i = i + 1
	free(grown)

	# A block bigger than one page still gets exactly one trailing guard
	# page and is fully writable up to the requested size.
	char* big = malloc(10000)
	big[0] = 1
	big[9999] = 1
	free(big)

	# Grow a barely-used string_builder in one jump past its capacity.
	# realloc oldlen must be capacity (not length+1); under the debug
	# allocator a mismatch is fatal.
	string_builder* sb = string_new_sized(16)
	asserts(c"fresh builder empty", sb.length == 0)
	string_reserve(sb, 100)
	asserts(c"reserve grew capacity", sb.capacity >= 101)
	string_append(sb, c"ok")
	asserts(c"append after large reserve", string_equals(sb, c"ok"))
	string_free(sb)

	asserts(c"no leaks yet", debug_alloc_report_leaks() == 0)

	malloc(37)
	malloc(5)
	asserts(c"two deliberate leaks reported", debug_alloc_report_leaks() == 2)

	println2(c"memory_debug_test: OK")
	return 0
