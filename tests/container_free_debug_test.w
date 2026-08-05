# wbuild: x64
# Leak-accounting proof for the container free() pseudo-method: the same
# allocate/populate/free churn tests/container_free_test.w runs under the
# freelist allocator, here under lib/memory_debug.w (forced on via
# malloc_force_debug_mode(), like tests/memory_debug_test.w). After many
# rounds covering every kind of storage a container owns -- growing
# backing arrays, struct element slots, rehashed tables, cloned char*
# and string keys (including clones released by remove) -- the debug
# allocator must report zero outstanding allocations, proving free()
# returns every byte through the allocator that produced it.
import lib.lib
import lib.assert
import lib.memory


struct cfd_point:
	int x
	int y


void cfd_round():
	# list growth past the initial capacity of 8 exercises realloc
	list[int] l = new list[int]
	int i = 0
	while (i < 40):
		l.push(i)
		i = i + 1
	assert_equal(40, l.length)
	l.free()

	# struct elements occupy word-rounded byte slots
	list[cfd_point] pts = new list[cfd_point]
	cfd_point p
	p.x = 1
	p.y = 2
	pts.push(p)
	p.y = 4
	pts.push(p)
	pts.free()

	# 40 int keys rehash the table twice (grow at count * 4 >= capacity * 3)
	map[int, int] m = new map[int, int]
	i = 0
	while (i < 40):
		m[i] = i * 3
		i = i + 1
	assert_equal(40, m.length)
	m.free()

	# char* keys are cloned on insert; remove frees one clone early and
	# free() releases the survivors
	map[char*, int] names = new map[char*, int]
	names[c"alpha"] = 1
	names[c"beta"] = 2
	names[c"gamma"] = 3
	names.remove(c"beta")
	assert_equal(2, names.length)
	names.free()

	# string keys clone descriptor and bytes
	map[string, int] sm = new map[string, int]
	sm[s"one"] = 1
	sm[s"two"] = 2
	sm.free()

	set[char*] s = new set[char*]
	s.add(c"walnut")
	s.add(c"acorn")
	s.remove(c"walnut")
	s.free()

	# free() does not chase element pointers: the caller frees the inner
	# lists, the outer free releases only its own storage
	list[list[int]] outer = new list[list[int]]
	i = 0
	while (i < 3):
		list[int] inner = new list[int]
		inner.push(i)
		outer.push(inner)
		i = i + 1
	for list[int] inner in outer:
		inner.free()
	outer.free()


int main():
	malloc_force_debug_mode()
	int round = 0
	while (round < 200):
		cfd_round()
		round = round + 1
	asserts(c"container free churn left no leaks", debug_alloc_report_leaks() == 0)
	println2(c"container_free_debug_test: OK")
	return 0
