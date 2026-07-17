import lib.testing


# issue #189, 64-bit half: map[K, float64] values round-tripping through
# the word-based __w_map_set/__w_map_get path. float64 requires the x64
# target (the compiler rejects it on 32-bit words), so unlike
# tests/map_float_test.w this file is x64-only: its target is
# hand-written in build.base.json (like x64_float_test), compiled with
# the `x64` selector, and there is no 32-bit twin. Values are asserted
# bit-exactly, split into low/high 32-bit halves the same way
# x64_float_test.w's assert_float64_bits does; 0.1 and 2^53 + 3 pin bits
# that a float32 (or a 32-bit word) could not represent, proving the
# full 64-bit payload survives storage in a map slot.
void assert_f64_bits(int want_lo, int want_hi, float64 got):
	char* p = &got
	assert_equal_hex(want_lo, load_int32(p))
	assert_equal_hex(want_hi, load_int32(p + 4))


void test_map_int_float64_set_get_roundtrip():
	map[int, float64] m = new map[int, float64]
	m[1] = 1.5
	m[2] = -2.25
	m[3] = 0.0
	m[4] = 0.1
	m[5] = 10000000000.0
	m[6] = 9007199254740995.0 /* 2^53 + 3 rounds to 2^53 + 2: low bit 0x2 */
	assert_f64_bits(0x0, 0x3ff80000, m[1])
	assert_f64_bits(0x0, cast(int, 0xc0020000), m[2])
	assert_f64_bits(0x0, 0x0, m[3])
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, m[4])
	assert_f64_bits(0x20000000, 0x4202a05f, m[5])
	assert_f64_bits(0x00000002, 0x43400000, m[6])
	assert_equal(6, m.length)


void test_map_char_ptr_float64_literal():
	map[char*, float64] m = map[char*, float64]{c"a": 1.5, c"b": 0.1}
	assert_f64_bits(0x0, 0x3ff80000, m[c"a"])
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, m[c"b"])
	assert_equal(2, m.length)


void test_map_float64_overwrite():
	map[char*, float64] m = new map[char*, float64]
	m[c"k"] = 1.5
	m[c"k"] = -2.25
	assert_f64_bits(0x0, cast(int, 0xc0020000), m[c"k"])
	assert_equal(1, m.length)


void test_map_float64_get_with_default():
	map[char*, float64] m = map[char*, float64]{c"one": 3.5}
	assert_f64_bits(0x0, 0x400c0000, m.get(c"one"))
	assert_f64_bits(0x0, 0x400c0000, m.get(c"one", 9.0))
	assert_f64_bits(0x0, 0x40220000, m.get(c"missing", 9.0))
	# a present key still overrides the default even when it is 0.0
	map[char*, float64] zero_map = map[char*, float64]{c"zero": 0.0}
	assert_f64_bits(0x0, 0x0, zero_map.get(c"zero", 5.0))


void test_map_float64_membership_and_remove():
	map[int, float64] m = new map[int, float64]
	m[7] = 3.5
	m[8] = 100.25
	assert_equal(1, 7 in m)
	assert_equal(0, 9 in m)
	assert_equal(1, m.remove(7))
	assert_equal(0, 7 in m)
	assert_equal(1, m.length)
	assert_equal(0, m.remove(7))
	# a removed key can be inserted again
	m[7] = -100.25
	assert_f64_bits(0x0, cast(int, 0xc0591000), m[7])
	assert_f64_bits(0x0, 0x40591000, m[8])
	assert_equal(2, m.length)


void test_map_float64_keys_and_values_snapshot():
	map[int, float64] m = new map[int, float64]
	m[7] = 0.5
	m[3] = 0.1
	list[int] keys = m.keys()
	assert_equal(2, keys.length)
	assert_equal(7, keys[0])
	assert_equal(3, keys[1])
	list[float64] vals = m.values()
	assert_equal(2, vals.length)
	assert_f64_bits(0x0, 0x3fe00000, vals[0])
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, vals[1])
	# a later map write must not affect the snapshot
	m[7] = 1.0
	assert_f64_bits(0x0, 0x3fe00000, vals[0])


void test_map_float64_for_two_var_iteration_sums_values():
	map[int, float64] m = new map[int, float64]
	m[0] = 1.0
	m[1] = 2.0
	m[2] = 4.0
	m[3] = 8.0
	m[4] = 16.0
	int count = 0
	float64 sum = 0.0
	for int k, float64 v in m:
		count = count + 1
		sum = sum + v
	assert_equal(5, count)
	assert_f64_bits(0x0, 0x403f0000, sum)


void test_map_float64_iteration_keeps_full_precision():
	# 1.5 + 0.1 = 0x3ff999999999999a: only correct when the map stored
	# and iterated all 64 value bits, not a float32 truncation
	map[int, float64] m = new map[int, float64]
	m[1] = 1.5
	m[2] = 0.1
	float64 sum = 0.0
	for int k, float64 v in m:
		sum = sum + v
	assert_f64_bits(cast(int, 0x9999999a), 0x3ff99999, sum)


void test_map_float64_compound_assignment_ops():
	map[char*, float64] m = new map[char*, float64]
	m[c"n"] = 8.0
	m[c"n"] += 4.0
	assert_f64_bits(0x0, 0x40280000, m[c"n"])
	m[c"n"] -= 2.0
	assert_f64_bits(0x0, 0x40240000, m[c"n"])
	m[c"n"] *= 0.5
	assert_f64_bits(0x0, 0x40140000, m[c"n"])
	m[c"n"] /= 2.0
	assert_f64_bits(0x0, 0x40040000, m[c"n"])
	assert_equal(1, m.length)


# m.add(key[, delta]) on float64 values (issue #189): a missing key
# accumulates from 0.0 instead of trapping, and the add runs at float64
# width on the stored 64-bit payload.
void test_map_float64_add_accumulates_from_zero():
	map[char*, float64] m = new map[char*, float64]
	assert_f64_bits(0x0, 0x3ff80000, m.add(c"k", 1.5))
	m.add(c"k", 0.25)
	assert_f64_bits(0x0, 0x3ffc0000, m[c"k"])
	assert_equal(1, m.length)


void test_map_float64_add_default_delta_and_return():
	map[int, float64] m = new map[int, float64]
	m.add(5)
	assert_f64_bits(0x0, 0x3ff00000, m[5])
	float64 got = m.add(5, 0.5)
	assert_f64_bits(0x0, 0x3ff80000, got)
	m.add(5, 2)
	assert_f64_bits(0x0, 0x400c0000, m[5])


void test_map_float64_add_keeps_full_precision():
	# 1.5 + 0.1 = 0x3ff999999999999a: only right when the add ran at
	# float64 width on all 64 stored value bits, not a float32 add on
	# the low word
	map[int, float64] m = new map[int, float64]
	m.add(1, 1.5)
	m.add(1, 0.1)
	assert_f64_bits(cast(int, 0x9999999a), 0x3ff99999, m[1])


void test_map_float64_add_mixed_with_get_default():
	map[char*, float64] m = new map[char*, float64]
	assert_f64_bits(0x0, 0x40220000, m.get(c"k", 9.0))
	m.add(c"k", 0.5)
	assert_f64_bits(0x0, 0x3fe00000, m.get(c"k", 9.0))
	list[float64] vals = m.values()
	assert_equal(1, vals.length)
	assert_f64_bits(0x0, 0x3fe00000, vals[0])
