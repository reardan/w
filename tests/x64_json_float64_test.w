# wbuild: arch_only=x64
import lib.testing
import structures.json


# float64 fields in to_json/from_json, and the float64 number carriage
# in structures/json.w behind them (docs/projects/protocol_ergonomics.md
# follow-on). float64 requires an 8-byte word, so like
# tests/x64_map_float64_test.w this file is x64-only via the
# arch_only=x64 directive and has no 32-bit twin (the 32-bit story is
# pinned by tests/json_codec_float64_x86_error_fixture.w: the type
# itself is a compile error there). Values are asserted bit-exactly,
# split into low/high 32-bit halves the same way that test's
# assert_f64_bits does, because a 17-digit float64 needs bit compares a
# float32 (or a 32-bit word) could not express. The text round trips
# below are the point of the feature: encode -> stringify -> parse ->
# decode must reproduce the exact source bits.


struct jf_reading:
	char* name
	float64 a
	float64 b


struct jf_nested:
	jf_reading inner
	float64 scale


struct jf_bulk:
	list[float64] values
	map[char*, float64] table


struct jf_mixed:
	float narrow
	float64 wide


void assert_f64_bits(int want_lo, int want_hi, float64 got):
	char* p = &got
	assert_equal_hex(want_lo, load_int32(p))
	assert_equal_hex(want_hi, load_int32(p + 4))


float64 f64_from_halves(int lo, int hi):
	int bits = (hi << 32) | (lo & ((1 << 32) - 1))
	float64* p = cast(float64*, &bits)
	return *p


# One full text round trip of a struct value: encode, stringify,
# re-parse, decode, and hand back the decoded struct.
jf_reading* jf_text_round_trip(jf_reading* r):
	json_value* v = to_json(r)
	char* text = json_stringify(v)
	json_free(v)
	json_value* back = json_parse(text)
	assert1(back != 0)
	free(text)
	jf_reading* q = from_json(jf_reading, back)
	json_free(back)
	assert1(cast(int, q) != 0)
	return q


void test_tree_round_trip_is_bit_exact():
	# to_json carries the raw bits into the json_value and from_json
	# carries them back out: exact for any finite pattern, including
	# ones no 17-digit decimal walk is even consulted for
	jf_reading r
	r.name = c"t"
	r.a = 0.1
	r.b = 9007199254740994.0 /* 2^53 + 2: needs all 64 bits */
	json_value* v = to_json(r)
	jf_reading* q = from_json(jf_reading, v)
	assert1(cast(int, q) != 0)
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, q.a)
	assert_f64_bits(0x00000001, 0x43400000, q.b)
	json_free(v)


void test_text_round_trip_is_bit_exact():
	# stringify emits up to 17 significant digits and verifies them by
	# re-parsing, so text round trips reproduce exact bits: fractions a
	# float32 cannot hold, pi, huge, tiny, and the largest finite value
	jf_reading r
	r.name = c"hard"
	r.a = 3.141592653589793
	r.b = 0.1
	jf_reading* q = jf_text_round_trip(&r)
	assert_f64_bits(0x54442d18, 0x400921fb, q.a)
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, q.b)

	r.a = 1e100
	r.b = 1e-300
	q = jf_text_round_trip(&r)
	assert_f64_bits(0x2594c37d, 0x54b249ad, q.a)
	assert_f64_bits(cast(int, 0xc2f8f359), 0x01a56e1f, q.b)

	r.a = 1.7976931348623157e308  /* largest finite float64 */
	r.b = 6.02214076e23
	q = jf_text_round_trip(&r)
	assert_f64_bits(cast(int, 0xffffffff), 0x7fefffff, r.a)
	assert_f64_bits(cast(int, 0xffffffff), 0x7fefffff, q.a)
	assert_f64_bits(cast(int, 0xca57c517), 0x44dfe185, q.b)


void test_text_round_trip_denormal_and_negative_zero():
	jf_reading r
	r.name = c"edge"
	r.a = 4.9406564584124654e-324  /* smallest denormal */
	r.b = f64_from_halves(0x0, cast(int, 0x80000000))  /* -0.0 */
	jf_reading* q = jf_text_round_trip(&r)
	assert_f64_bits(0x00000001, 0x00000000, q.a)
	# the float64 formatter keeps the sign of a negative zero
	assert_f64_bits(0x00000000, cast(int, 0x80000000), q.b)


void test_encode_pins_serialized_text():
	jf_reading r
	r.name = c"t"
	r.a = 1.5
	r.b = -0.25
	json_value* v = to_json(r)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22name\x22:\x22t\x22,\x22a\x22:1.5,\x22b\x22:-0.25}", text)
	free(text)
	json_free(v)

	# whole values keep a .0, fractions stay shortest-per-17-digits,
	# and extreme exponents go scientific
	r.a = 9007199254740994.0
	r.b = 0.1
	v = to_json(r)
	text = json_stringify(v)
	assert_strings_equal(c"{\x22name\x22:\x22t\x22,\x22a\x22:9007199254740994.0,\x22b\x22:0.1}", text)
	free(text)
	json_free(v)

	r.a = 1e100
	r.b = 1e-300
	v = to_json(r)
	text = json_stringify(v)
	assert_strings_equal(c"{\x22name\x22:\x22t\x22,\x22a\x22:1e100,\x22b\x22:1e-300}", text)
	free(text)
	json_free(v)


void test_parse_keeps_float64_precision():
	# structures/json.w itself: a parsed fraction carries the full
	# float64 reading next to the float32 mirror
	json_value* v = json_parse(c"0.1")
	assert1(v != 0)
	assert_equal(json_type_float(), v.type)
	assert_equal(1, v.has_float64)
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, f64_from_halves(v.float64_bits & ((1 << 32) - 1), v.float64_bits >> 32))
	assert_equal(json_float_bits(0.1), json_float_bits(v.float_value))
	json_free(v)


void test_decode_from_parsed_text_keeps_precision():
	# The value distinguishes float64 from a widened float32: parsing
	# 0.1 through a float32 would decode to 0x3fb999999a000000-ish, not
	# the ...999a pattern
	json_value* v = json_parse(c"{\x22name\x22:\x22pi\x22,\x22a\x22:3.141592653589793,\x22b\x22:0.1}")
	assert1(v != 0)
	jf_reading* q = from_json(jf_reading, v)
	assert1(cast(int, q) != 0)
	assert_strings_equal(c"pi", q.name)
	assert_f64_bits(0x54442d18, 0x400921fb, q.a)
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, q.b)
	json_free(v)


void test_decode_accepts_int_and_float32_values():
	# a JSON integer converts (JavaScript writes whole doubles bare),
	# and a float32-only json_value (no float64 bits) widens
	json_value* v = json_parse(c"{\x22name\x22:\x22n\x22,\x22a\x22:3,\x22b\x22:2.5}")
	jf_reading* q = from_json(jf_reading, v)
	assert1(cast(int, q) != 0)
	assert_f64_bits(0x0, 0x40080000, q.a)
	assert_f64_bits(0x0, 0x40040000, q.b)
	json_free(v)

	json_value* obj = json_object()
	json_object_set(obj, c"name", json_string(c"w"))
	json_object_set(obj, c"a", json_float(1.5))
	json_object_set(obj, c"b", json_int(-2))
	q = from_json(jf_reading, obj)
	assert1(cast(int, q) != 0)
	assert_f64_bits(0x0, 0x3ff80000, q.a)
	assert_f64_bits(0x0, cast(int, 0xc0000000), q.b)
	json_free(obj)


void test_decode_wrong_type_fails():
	json_value* v = json_parse(c"{\x22name\x22:\x22n\x22,\x22a\x22:\x22cold\x22,\x22b\x22:1.5}")
	jf_reading* q = from_json(jf_reading, v)
	assert_equal(0, cast(int, q))
	json_free(v)


void test_decode_saturates_like_the_parser():
	# overflow saturates to the largest finite float64, underflow
	# flushes to signed zero: the parser's number contract carried
	# through the codec
	json_value* v = json_parse(c"{\x22name\x22:\x22s\x22,\x22a\x22:1e400,\x22b\x22:-1e400}")
	jf_reading* q = from_json(jf_reading, v)
	assert1(cast(int, q) != 0)
	assert_f64_bits(cast(int, 0xffffffff), 0x7fefffff, q.a)
	assert_f64_bits(cast(int, 0xffffffff), cast(int, 0xffefffff), q.b)
	json_free(v)

	v = json_parse(c"{\x22name\x22:\x22s\x22,\x22a\x22:1e-999,\x22b\x22:-1e-999}")
	q = from_json(jf_reading, v)
	assert1(cast(int, q) != 0)
	assert_f64_bits(0x0, 0x0, q.a)
	assert_f64_bits(0x0, cast(int, 0x80000000), q.b)
	json_free(v)


void test_nested_struct_fields_round_trip():
	jf_nested n
	n.inner.name = c"in"
	n.inner.a = 0.1
	n.inner.b = -2.25
	n.scale = 1e-15
	json_value* v = to_json(n)
	char* text = json_stringify(v)
	json_free(v)
	json_value* back = json_parse(text)
	free(text)
	jf_nested* q = from_json(jf_nested, back)
	json_free(back)
	assert1(cast(int, q) != 0)
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, q.inner.a)
	assert_f64_bits(0x0, cast(int, 0xc0020000), q.inner.b)
	assert_f64_bits(cast(int, 0x9ee75616), 0x3cd203af, q.scale)


void test_list_and_map_fields_round_trip():
	jf_bulk s
	s.values = new list[float64]
	s.values.push(0.1)
	s.values.push(-1e100)
	s.values.push(2.0)
	s.table = new map[char*, float64]
	s.table[c"pi"] = 3.141592653589793
	s.table[c"half"] = 0.5
	json_value* v = to_json(s)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22values\x22:[0.1,-1e100,2.0],\x22table\x22:{\x22pi\x22:3.141592653589793,\x22half\x22:0.5}}", text)
	json_free(v)
	json_value* back = json_parse(text)
	free(text)
	jf_bulk* q = from_json(jf_bulk, back)
	json_free(back)
	assert1(cast(int, q) != 0)
	assert_equal(3, q.values.length)
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, q.values[0])
	assert_f64_bits(0x2594c37d, cast(int, 0xd4b249ad), q.values[1])
	assert_f64_bits(0x0, 0x40000000, q.values[2])
	assert_equal(2, q.table.length)
	assert_f64_bits(0x54442d18, 0x400921fb, q.table[c"pi"])
	assert_f64_bits(0x0, 0x3fe00000, q.table[c"half"])


void test_float32_field_still_works_next_to_float64():
	jf_mixed m
	m.narrow = 1.5
	m.wide = 0.1
	json_value* v = to_json(m)
	char* text = json_stringify(v)
	assert_strings_equal(c"{\x22narrow\x22:1.5,\x22wide\x22:0.1}", text)
	json_free(v)
	json_value* back = json_parse(text)
	free(text)
	jf_mixed* q = from_json(jf_mixed, back)
	json_free(back)
	assert1(cast(int, q) != 0)
	assert_equal(json_float_bits(1.5), json_float_bits(q.narrow))
	assert_f64_bits(cast(int, 0x9999999a), 0x3fb99999, q.wide)


void test_non_finite_bits_stringify_as_null():
	# like the float32 side: no JSON spelling for inf/nan
	json_value* v = json_float64_from_bits(0x7ff << 52)
	char* text = json_stringify(v)
	assert_strings_equal(c"null", text)
	free(text)
	json_free(v)
	v = json_float64_from_bits((0x7ff << 52) | 1)
	text = json_stringify(v)
	assert_strings_equal(c"null", text)
	free(text)
	json_free(v)
