# wbuild: x64
# End-to-end coverage for the container free() pseudo-method (issue #26 /
# docs/projects/typed_containers.md) under the default freelist allocator;
# tests/container_free_debug_test.w runs the same churn under the
# guard-page debug allocator's leak accounting. Contract exercised here:
# l.free()/m.free()/s.free() release the container's OWNED storage
# (backing arrays, cloned string keys, the header) through the same
# allocator the runtime used, element/value POINTERS are not chased, and
# using the variable after free() is caller error, like lib/memory.w's
# free().
#
# The address-reuse assertions match lib/memory_freelist.w's behavior:
# freed blocks are pushed onto LIFO exact-size bins, so an identical
# allocate/populate/free cycle reaches a steady state (from the second
# cycle on) where every cycle gets its header back from the same block --
# repeated churn cannot grow the heap. The post-free .length reads assert
# the documented best-effort header zeroing; they rely on the freelist
# backend leaving freed payload bytes intact until reuse, so this test
# must not run with W_DEBUG_ALLOC set (the debug backend unmaps freed
# pages, which tests/memory_debug_uaf_fixture.w covers instead).
import lib.assert
import lib.lib


struct cf_point:
	int x
	int y


# One list allocate/populate/free cycle, with enough pushes to grow past
# the initial capacity of 8 so the realloc path runs too. Returns the
# header's address for the steady-state reuse assertion.
int cf_list_cycle():
	list[int] l = new list[int]
	int i = 0
	while (i < 40):
		l.push(i)
		i = i + 1
	assert_equal(40, l.length)
	int addr = cast(int, l)
	l.free()
	return addr


# One map cycle: 40 int keys force the table to rehash (grow triggers at
# count * 4 >= capacity * 3, so twice from the initial capacity of 16).
int cf_map_cycle():
	map[int, int] m = new map[int, int]
	int i = 0
	while (i < 40):
		m[i] = i * 3
		i = i + 1
	assert_equal(40, m.length)
	assert_equal(60, m[20])
	int addr = cast(int, m)
	m.free()
	return addr


# One set cycle with cloned char* keys, including a remove, so free()
# releases both the arrays and the surviving key clones.
int cf_set_cycle():
	set[char*] s = new set[char*]
	s.add(c"walnut")
	s.add(c"acorn")
	s.add(c"pecan")
	s.remove(c"acorn")
	assert_equal(2, s.length)
	int addr = cast(int, s)
	s.free()
	return addr


void test_steady_state_reuse():
	# Cycle 0 bump-allocates fresh blocks; every later cycle must get its
	# header back from the freelist, so the address repeats forever.
	cf_list_cycle()
	int want = cf_list_cycle()
	int round = 0
	while (round < 2000):
		assert_equal(want, cf_list_cycle())
		round = round + 1

	cf_map_cycle()
	want = cf_map_cycle()
	round = 0
	while (round < 2000):
		assert_equal(want, cf_map_cycle())
		round = round + 1

	cf_set_cycle()
	want = cf_set_cycle()
	round = 0
	while (round < 2000):
		assert_equal(want, cf_set_cycle())
		round = round + 1


void test_struct_elements_and_string_keys():
	list[cf_point] pts = new list[cf_point]
	cf_point p
	p.x = 1
	p.y = 2
	pts.push(p)
	p.x = 3
	pts.push(p)
	assert_equal(2, pts.length)
	pts.free()

	map[string, int] m = new map[string, int]
	m[s"one"] = 1
	m[s"two"] = 2
	assert_equal(1, m[s"one"])
	m.free()


# free() does not chase element pointers: inner containers are freed by
# the caller, then the outer list releases only its own storage.
void test_nested_containers_freed_by_caller():
	list[list[int]] outer = new list[list[int]]
	int i = 0
	while (i < 3):
		list[int] inner = new list[int]
		inner.push(i)
		outer.push(inner)
		i = i + 1
	assert_equal(3, outer.length)
	for list[int] inner in outer:
		inner.free()
	outer.free()


# Documented best-effort safety: __w_list_free/__w_map_free zero the
# header before releasing it, and the freelist backend only rewrites the
# block's own header words on free -- so with no intervening allocation a
# stale .length reads 0 (and stale indexing or pop traps on the empty
# shape) instead of returning plausible garbage. Each stale read happens
# before the next container is allocated, since that allocation reuses
# the just-freed header block.
void test_freed_header_reads_zero_length():
	list[int] l = new list[int]
	l.push(7)
	assert_equal(1, l.length)
	l.free()
	assert_equal(0, l.length)

	map[int, int] m = new map[int, int]
	m[1] = 2
	assert_equal(1, m.length)
	m.free()
	assert_equal(0, m.length)

	set[int] s = new set[int]
	s.add(3)
	assert_equal(1, s.length)
	s.free()
	assert_equal(0, s.length)


int main():
	test_steady_state_reuse()
	test_struct_elements_and_string_keys()
	test_nested_containers_freed_by_caller()
	test_freed_header_reads_zero_length()
	println2(c"container_free_test: OK")
	return 0
