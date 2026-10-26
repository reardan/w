# wbuild: arch_only=x64
/*
A failed segment registration leaves no registry entries behind
(lib/thread_heap.w th_register, #699 review finding 1).

A range whose segments sit under two different registry leaves (x64
only: a leaf covers one 4GB slice of the address space) needs a leaf
mmap per slice. When the second one is refused, th_register used to
return 0 with the first segment still recorded as the heap's, and its
caller then unmapped the range: a later mapping there, such as a
main-heap mmap chunk, would look like that heap's memory to th_free.

The test registers a fake two-segment range straddling a 4GB boundary.
The first slice's leaf exists beforehand; RLIMIT_AS is lowered to the
current address-space size so the second leaf's mmap fails. Nothing
is mapped at the range itself: th_register only writes the registry,
and no allocator hooks are installed.
*/
import lib.assert
import lib.thread_heap


# The process's address-space size in bytes (/proc/self/statm, first
# field, in pages).
int vm_size():
	int fd = open(c"/proc/self/statm", 0, 0)
	asserts(c"open statm", fd >= 0)
	char[128] buf
	int n = read(fd, &buf[0], 127)
	close(fd)
	asserts(c"read statm", n > 0)
	buf[n] = 0
	return atoi(&buf[0]) * 4096


# prlimit64(0, RLIMIT_AS, new, old) on struct rlimit64 (two u64 words).
int limit_as(int* new_limit, int* old_limit):
	return syscall7(302, 0, 9, cast(int, new_limit), cast(int, old_limit), 0, 0)


void test_failed_register_rolls_back():
	th_registry = th_mmap(32768 * __word_size__)
	asserts(c"registry mapped", th_registry != 0)
	int seg = th_segment_size()
	# The last segment below 24GB and the first one above it: leaves 5
	# and 6 of the top-level table.
	int base = (6 << 32) - seg
	wheap* h = cast(wheap*, 4096)
	asserts(c"first leaf", cast(int, th_registry_leaf(base, 1)) != 0)
	assert_equal(0, cast(int, th_registry_leaf(base + seg, 0)))

	int[2] original
	int[2] tight
	assert_equal(0, limit_as(cast(int*, 0), &original[0]))
	tight[0] = vm_size()
	tight[1] = original[1]
	assert_equal(0, limit_as(&tight[0], cast(int*, 0)))
	int registered = th_register(base, 2 * seg, h)
	assert_equal(0, limit_as(&original[0], cast(int*, 0)))

	assert_equal(0, registered)
	assert_equal(0, cast(int, th_owner(base)))
	assert_equal(0, cast(int, th_owner(base + seg)))

	# With memory available the same range registers whole.
	assert_equal(1, th_register(base, 2 * seg, h))
	assert_equal(cast(int, h), cast(int, th_owner(base)))
	assert_equal(cast(int, h), cast(int, th_owner(base + seg)))


int main():
	test_failed_register_rolls_back()
	print(c"thread_heap_register OK\n")
	return 0
