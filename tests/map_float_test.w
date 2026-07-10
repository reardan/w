# wbuild: x64
import lib.testing


# issue #189: map[K, float] values had zero test coverage. These tests
# pin exact float32 round-tripping through __w_map_set/__w_map_get (and
# friends) using bit-exact comparisons, the same technique float_test.w
# and float_literal_test.w use for exactly-representable values. This
# test also runs as a 64-bit twin (# wbuild: x64), so the load must use
# load_int32 rather than a plain load_i(p, 4): a hex literal with bit 31
# set sign-extends into the word-sized int on a 64-bit host, and
# load_int32 mirrors that sign-extension on read (see x64_float_test.w's
# assert_float32_bits), while a bare load_i(p, 4) would not.
void assert_float_bits(int want, float got):
	char* p = &got
	assert_equal_hex(want, load_int32(p))


void test_map_char_ptr_float_set_get_roundtrip():
	map[char*, float] m = new map[char*, float]
	m[c"a"] = 1.5
	m[c"b"] = -2.25
	m[c"c"] = 0.0
	m[c"d"] = 1073741824.0
	assert_float_bits(0x3fc00000, m[c"a"])
	assert_float_bits(0xc0100000, m[c"b"])
	assert_float_bits(0x0, m[c"c"])
	assert_float_bits(0x4e800000, m[c"d"])
	assert_equal(4, m.length)


void test_map_int_float_set_get_roundtrip():
	map[int, float] m = new map[int, float]
	m[1] = 1.5
	m[2] = -2.25
	m[3] = 0.0
	m[4] = 1073741824.0
	assert_float_bits(0x3fc00000, m[1])
	assert_float_bits(0xc0100000, m[2])
	assert_float_bits(0x0, m[3])
	assert_float_bits(0x4e800000, m[4])
	assert_equal(4, m.length)


void test_map_float_literal():
	map[char*, float] m = map[char*, float]{c"a": 1.5, c"b": -2.25}
	assert_float_bits(0x3fc00000, m[c"a"])
	assert_float_bits(0xc0100000, m[c"b"])
	assert_equal(2, m.length)


void test_map_float_overwrite():
	map[char*, float] m = new map[char*, float]
	m[c"k"] = 1.5
	m[c"k"] = -2.25
	assert_float_bits(0xc0100000, m[c"k"])
	assert_equal(1, m.length)


void test_map_float_get():
	map[char*, float] m = map[char*, float]{c"one": 1.5, c"two": -2.25}
	assert_float_bits(0x3fc00000, m.get(c"one"))
	assert_float_bits(0xc0100000, m.get(c"two"))


void test_map_float_get_with_default():
	map[char*, float] m = map[char*, float]{c"one": 3.5}
	assert_float_bits(0x40600000, m.get(c"one", 9.0))
	assert_float_bits(0x41100000, m.get(c"missing", 9.0))
	# a present key still overrides the default even when it is 0.0
	map[char*, float] zero_map = map[char*, float]{c"zero": 0.0}
	assert_float_bits(0x0, zero_map.get(c"zero", 5.0))


void test_map_float_remove():
	map[char*, float] m = map[char*, float]{c"one": 1.5, c"two": -2.25, c"three": 100.25}
	assert_equal(1, m.remove(c"two"))
	assert_equal(2, m.length)
	assert_equal(0, c"two" in m)
	assert_float_bits(0x3fc00000, m[c"one"])
	assert_float_bits(0x42c88000, m[c"three"])
	# Removing a missing key reports false and changes nothing
	assert_equal(0, m.remove(c"two"))
	assert_equal(2, m.length)
	# A removed key can be inserted again
	m[c"two"] = -100.25
	assert_float_bits(0xc2c88000, m[c"two"])
	assert_equal(3, m.length)


void test_map_float_membership():
	map[int, float] m = new map[int, float]
	m[7] = 3.5
	assert_equal(1, 7 in m)
	assert_equal(0, 8 in m)


void test_map_float_for_single_var_iteration():
	map[char*, float] m = map[char*, float]{c"a": 1.0, c"b": 2.0, c"c": 4.0}
	int count = 0
	float sum = 0.0
	for char* key in m:
		count = count + 1
		sum = sum + m[key]
	assert_equal(3, count)
	assert_float_bits(0x40e00000, sum)


void test_map_float_for_two_var_iteration_sums_values():
	map[int, float] m = new map[int, float]
	m[0] = 1.0
	m[1] = 2.0
	m[2] = 4.0
	m[3] = 8.0
	m[4] = 16.0
	int count = 0
	float sum = 0.0
	for int k, float v in m:
		count = count + 1
		sum = sum + v
	assert_equal(5, count)
	assert_float_bits(0x41f80000, sum)


# m[k] op= v: the map/hash_builtin compound assignment path (issue #189
# left the .add() decision for floats open, but += -= *= /= go through
# the same compound_assign_apply as ordinary float variables and are not
# part of that deferred decision) is exercised here since it is not
# guarded against float values and works correctly.
void test_map_float_compound_assignment_ops():
	map[char*, float] m = new map[char*, float]
	m[c"n"] = 8.0
	m[c"n"] += 4.0
	assert_float_bits(0x41400000, m[c"n"])
	m[c"n"] -= 2.0
	assert_float_bits(0x41200000, m[c"n"])
	m[c"n"] *= 0.5
	assert_float_bits(0x40a00000, m[c"n"])
	m[c"n"] /= 2.0
	assert_float_bits(0x40200000, m[c"n"])
	assert_equal(1, m.length)


void test_map_float_compound_assignment_yields_stored_value():
	map[int, float] m = new map[int, float]
	m[1] = 2.0
	float got = m[1] += 3.0
	assert_float_bits(0x40a00000, got)
	assert_float_bits(0x40a00000, m[1])


void test_map_float_compound_assignment_rhs_reads_same_map():
	map[int, float] m = new map[int, float]
	m[1] = 10.0
	m[2] = 4.0
	m[1] += m[2]
	assert_float_bits(0x41600000, m[1])
