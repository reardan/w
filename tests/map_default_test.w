# Opt-in missing-key defaults for maps: new map[K, V](value|factory) and
# the synthesized empty-container default new map[K, container]() —
# issue #327, design in docs/projects/map_default_factory.md. The trap
# contract for maps built WITHOUT the argument list is pinned by
# tests/map_default_trap_test.w and container_trap_test.
# wbuild: x64
import lib.testing


int md_factory_calls


int md_next_hundred():
	md_factory_calls = md_factory_calls + 1
	return md_factory_calls * 100


map[char*, int] md_make_counter():
	return new map[char*, int](0)


map[char*, map[char*, int]] md_make_middle():
	return new map[char*, map[char*, int]]()


struct md_point:
	int x
	int y


md_point* md_new_point():
	md_point* p = new md_point
	p.x = 7
	p.y = 8
	return p


void test_scalar_default_read_inserts():
	map[char*, int] m = new map[char*, int](0)
	m[c"present"] = 5
	# unlike m.get(k, default), a defaulted read INSERTS the key
	assert_equal(0, m[c"missing"])
	assert_equal(2, m.length)
	assert_equal(1, c"missing" in m)
	list[char*] keys = m.keys()
	assert_equal(2, keys.length)
	assert_strings_equal(c"present", keys[0])
	assert_strings_equal(c"missing", keys[1])


void test_nonzero_scalar_default():
	map[int, int] m = new map[int, int](10)
	assert_equal(10, m[7])
	# the vivified value is stored, not recomputed
	m[7] = m[7] + 1
	assert_equal(11, m[7])
	assert_equal(1, m.length)


void test_float_scalar_default():
	map[char*, float] m = new map[char*, float](2.5)
	assert_equal(1, m[c"missing"] == 2.5)
	assert_equal(1, m.length)


void test_counter_compound_assign_from_missing():
	map[char*, int] counts = new map[char*, int](0)
	counts[c"a"] += 1
	counts[c"a"] += 1
	counts[c"b"] += 5
	counts[c"c"] -= 2
	assert_equal(2, counts[c"a"])
	assert_equal(5, counts[c"b"])
	assert_equal(0 - 2, counts[c"c"])
	assert_equal(3, counts.length)


void test_scalar_factory_called_per_missing_key():
	md_factory_calls = 0
	map[char*, int] ids = new map[char*, int](md_next_hundred)
	assert_equal(100, ids[c"first"])
	assert_equal(200, ids[c"second"])
	assert_equal(2, md_factory_calls)
	# present keys never invoke the factory
	assert_equal(100, ids[c"first"])
	assert_equal(2, md_factory_calls)


void test_nested_factory_auto_vivifies():
	map[char*, map[char*, int]] outer = new map[char*, map[char*, int]](md_make_counter)
	outer[c"x"][c"b"] += 1
	outer[c"x"][c"b"] += 1
	outer[c"x"][c"c"] += 3
	assert_equal(2, outer[c"x"][c"b"])
	assert_equal(3, outer[c"x"][c"c"])
	# the second key reused the existing inner map, no re-vivification
	assert_equal(1, outer.length)
	assert_equal(2, outer[c"x"].length)


void test_synthesized_map_of_map_default():
	# argument omitted: the compiler synthesizes the empty-map factory,
	# and the inner map's arithmetic scalar values zero-default, so the
	# full defaultdict(defaultdict(int)) shape needs no user factory
	map[char*, map[char*, int]] m = new map[char*, map[char*, int]]()
	m[c"k"][c"v"] += 7
	assert_equal(7, m[c"k"][c"v"])
	assert_equal(1, m.length)
	assert_equal(1, m[c"k"].length)


void test_synthesized_map_of_list_default():
	map[char*, list[int]] groups = new map[char*, list[int]]()
	groups[c"g"].push(4)
	groups[c"g"].push(9)
	assert_equal(4, groups[c"g"][0])
	assert_equal(9, groups[c"g"][1])
	assert_equal(2, groups[c"g"].length)
	assert_equal(1, groups.length)


void test_synthesized_map_of_set_default():
	map[char*, set[int]] m = new map[char*, set[int]]()
	m[c"s"].add(3)
	assert_equal(1, 3 in m[c"s"])
	assert_equal(0, 4 in m[c"s"])
	assert_equal(1, m[c"s"].length)


void test_three_level_nesting_with_factories():
	# levels beyond the synthesized pair chain through explicit factories
	map[char*, map[char*, map[char*, int]]] deep = new map[char*, map[char*, map[char*, int]]](md_make_middle)
	deep[c"a"][c"b"][c"c"] += 1
	deep[c"a"][c"b"][c"c"] += 1
	assert_equal(2, deep[c"a"][c"b"][c"c"])
	assert_equal(1, deep.length)
	assert_equal(1, deep[c"a"].length)
	assert_equal(1, deep[c"a"][c"b"].length)


void test_pointer_factory_no_aliasing():
	map[char*, md_point*] m = new map[char*, md_point*](md_new_point)
	m[c"one"].x = 11
	m[c"two"].x = 22
	# each missing key got its own fresh struct
	assert_equal(11, m[c"one"].x)
	assert_equal(22, m[c"two"].x)
	assert_equal(8, m[c"one"].y)
	# the same key keeps the same vivified pointer
	assert_equal(1, m[c"one"] == m[c"one"])
	assert_equal(2, m.length)


void test_in_operator_does_not_vivify():
	map[char*, int] m = new map[char*, int](0)
	assert_equal(0, c"ghost" in m)
	assert_equal(0, m.length)


void test_get_with_explicit_default_does_not_insert():
	# two-argument get keeps its read-only, per-call-default contract
	# even on a defaulted map
	map[char*, int] m = new map[char*, int](10)
	assert_equal(42, m.get(c"missing", 42))
	assert_equal(0, m.length)
	# one-argument get is m[k]: it vivifies the map default
	assert_equal(10, m.get(c"missing"))
	assert_equal(1, m.length)


void test_add_stays_orthogonal_to_defaults():
	# m.add accumulates from the zero-initialized slot, never from the
	# map default (docs/projects/map_default_factory.md, open question 4)
	map[char*, int] m = new map[char*, int](10)
	assert_equal(1, m.add(c"k"))
	assert_equal(1, m[c"k"])
	assert_equal(3, m.add(c"k", 2))


void test_values_and_iteration_see_vivified_entries():
	map[char*, int] m = new map[char*, int](9)
	m[c"a"] = 1
	assert_equal(9, m[c"b"])
	list[int] values = m.values()
	assert_equal(2, values.length)
	assert_equal(1, values[0])
	assert_equal(9, values[1])
	int total = 0
	for char* key, int value in m:
		total = total + value
	assert_equal(10, total)


void test_vivified_entries_survive_growth():
	map[int, int] m = new map[int, int](1)
	for int i in range(40):
		m[i] += i
	assert_equal(40, m.length)
	# every slot vivified to 1, then accumulated its key
	assert_equal(1, m[0])
	assert_equal(40, m[39])
	# a fresh read after growth still vivifies
	assert_equal(1, m[40])
	assert_equal(41, m.length)
