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
#
# `float` is float32 on every target; the 64-bit float type is the
# separate float64, which the compiler rejects on 32-bit targets
# ("float64 requires the x64 target"). This file therefore sticks to
# float32-representable values so it can run on both arches;
# map[K, float64] coverage lives in the x64-only
# tests/x64_map_float64_test.w.
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
	assert_float_bits(cast(int, 0xc0100000), m[c"b"])
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
	assert_float_bits(cast(int, 0xc0100000), m[2])
	assert_float_bits(0x0, m[3])
	assert_float_bits(0x4e800000, m[4])
	assert_equal(4, m.length)


void test_map_float_literal():
	map[char*, float] m = map[char*, float]{c"a": 1.5, c"b": -2.25}
	assert_float_bits(0x3fc00000, m[c"a"])
	assert_float_bits(cast(int, 0xc0100000), m[c"b"])
	assert_equal(2, m.length)


void test_map_float_overwrite():
	map[char*, float] m = new map[char*, float]
	m[c"k"] = 1.5
	m[c"k"] = -2.25
	assert_float_bits(cast(int, 0xc0100000), m[c"k"])
	assert_equal(1, m.length)


void test_map_float_get():
	map[char*, float] m = map[char*, float]{c"one": 1.5, c"two": -2.25}
	assert_float_bits(0x3fc00000, m.get(c"one"))
	assert_float_bits(cast(int, 0xc0100000), m.get(c"two"))


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
	assert_float_bits(cast(int, 0xc2c88000), m[c"two"])
	assert_equal(3, m.length)


void test_map_float_membership():
	map[int, float] m = new map[int, float]
	m[7] = 3.5
	assert_equal(1, 7 in m)
	assert_equal(0, 8 in m)


void test_map_string_float_set_get():
	map[string, float] m = new map[string, float]
	string a = s"alpha"
	m[a] = 0.5
	m[s"beta"] = -2.25
	assert_equal(2, m.length)
	assert_equal(1, s"alpha" in m)
	assert_equal(0, s"gamma" in m)
	assert_float_bits(0x3f000000, m[s"alpha"])
	assert_float_bits(cast(int, 0xc0100000), m[s"beta"])
	assert_float_bits(0x3f000000, m.get(s"alpha"))
	assert_float_bits(0x41100000, m.get(s"gamma", 9.0))


void test_map_float_keys_snapshot():
	map[char*, float] m = new map[char*, float]
	m[c"zebra"] = 0.5
	m[c"apple"] = -2.25
	m[c"mango"] = 1.5
	list[char*] keys = m.keys()
	assert_equal(3, keys.length)
	# keys() preserves insertion order and each key still indexes its value
	assert_strings_equal(c"zebra", keys[0])
	assert_strings_equal(c"apple", keys[1])
	assert_strings_equal(c"mango", keys[2])
	assert_float_bits(0x3f000000, m[keys[0]])
	assert_float_bits(cast(int, 0xc0100000), m[keys[1]])
	assert_float_bits(0x3fc00000, m[keys[2]])


void test_map_float_values_snapshot():
	map[int, float] m = new map[int, float]
	m[7] = 0.5
	m[3] = -2.25
	list[float] vals = m.values()
	assert_equal(2, vals.length)
	assert_float_bits(0x3f000000, vals[0])
	assert_float_bits(cast(int, 0xc0100000), vals[1])
	# a later map write must not affect the snapshot
	m[7] = 1.0
	assert_float_bits(0x3f000000, vals[0])
	assert_float_bits(0x3f800000, m[7])


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


# m[k] op= v: the map/hash_builtin compound assignment path — += -= *=
# /= go through the same compound_assign_apply as ordinary float
# variables. The float m.add() path (further down) shares its float-add
# emitters but starts missing keys at 0.0 instead of trapping.
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


# m.add(key[, delta]) on float value types (issue #189, the deferred
# half): unlike m[k] += delta, a missing key does not trap — it
# accumulates from 0.0, matching the integer counter semantics. All
# values below are exact in float32 (0.25/0.5 steps), so the assertions
# are bit-exact.
void test_map_float_add_missing_key_starts_from_zero():
	map[char*, float] m = new map[char*, float]
	assert_float_bits(0x3fc00000, m.add(c"k", 1.5))
	assert_equal(1, m.length)
	assert_equal(1, c"k" in m)
	assert_float_bits(0x3fc00000, m[c"k"])


void test_map_float_add_accumulates():
	map[char*, float] m = new map[char*, float]
	m.add(c"k", 1.5)
	m.add(c"k", 2.25)
	assert_float_bits(0x40700000, m[c"k"])
	m.add(c"k", -0.25)
	assert_float_bits(0x40600000, m[c"k"])
	assert_equal(1, m.length)


void test_map_float_add_default_delta_is_one():
	map[int, float] m = new map[int, float]
	m.add(7)
	m.add(7)
	m[8] = 0.5
	m.add(8)
	assert_float_bits(0x40000000, m[7])
	assert_float_bits(0x3fc00000, m[8])
	assert_equal(2, m.length)


void test_map_float_add_returns_updated_value():
	map[int, float] m = new map[int, float]
	float got = m.add(3, 0.5)
	assert_float_bits(0x3f000000, got)
	assert_float_bits(0x3f800000, m.add(3, 0.5))
	assert_float_bits(0x40000000, m.add(3))


void test_map_float_add_int_delta_converts():
	map[char*, float] m = new map[char*, float]
	m.add(c"k", 2)
	assert_float_bits(0x40000000, m[c"k"])
	m.add(c"k", -1)
	assert_float_bits(0x3f800000, m[c"k"])


void test_map_float_add_mixed_with_get_default():
	map[char*, float] m = new map[char*, float]
	assert_float_bits(0x0, m.get(c"k", 0.0))
	m.add(c"k", 0.5)
	assert_float_bits(0x3f000000, m.get(c"k", 9.0))
	assert_float_bits(0x41100000, m.get(c"other", 9.0))
	assert_equal(1, m.length)


void test_map_float_add_seen_by_iteration_and_snapshots():
	map[char*, float] m = new map[char*, float]
	m[c"a"] = 1.0
	m.add(c"b", 2.5)
	m.add(c"a", 0.5)
	# an accumulated existing key keeps its insertion-order position
	list[char*] keys = m.keys()
	assert_equal(2, keys.length)
	assert_strings_equal(c"a", keys[0])
	assert_strings_equal(c"b", keys[1])
	list[float] vals = m.values()
	assert_equal(2, vals.length)
	assert_float_bits(0x3fc00000, vals[0])
	assert_float_bits(0x40200000, vals[1])
	float sum = 0.0
	for char* k, float v in m:
		sum = sum + v
	assert_float_bits(0x40800000, sum)


void test_map_float_add_after_remove_restarts_from_zero():
	map[int, float] m = new map[int, float]
	m.add(1, 4.5)
	assert_equal(1, m.remove(1))
	m.add(1, 0.25)
	assert_float_bits(0x3e800000, m[1])
	assert_equal(1, m.length)


int map_float_add_key_probe(int* calls):
	*calls = *calls + 1
	return 41


void test_map_float_add_key_evaluated_once():
	map[int, float] m = new map[int, float]
	int calls = 0
	m.add(map_float_add_key_probe(&calls), 0.5)
	m.add(map_float_add_key_probe(&calls), 0.5)
	assert_equal(2, calls)
	assert_float_bits(0x3f800000, m[41])
