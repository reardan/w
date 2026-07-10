import lib.testing
import structures.json
import structures.string


void assert_json_string(json_value* value, char* want):
	assert_equal(json_type_string(), value.type)
	assert_strings_equal(want, value.string_value)


void assert_json_int(json_value* value, int want):
	assert_equal(json_type_int(), value.type)
	assert_equal(want, value.int_value)


char* json_test_take_string_data(string_builder* s):
	char* data = s.data
	free(s)
	return data


char* json_nested_array_text(int depth):
	string_builder* s = string_new()
	int i = 0
	while (i < depth):
		string_append_char(s, '[')
		i = i + 1
	string_append_char(s, '0')
	while (i > 0):
		string_append_char(s, ']')
		i = i - 1
	return json_test_take_string_data(s)


void assert_json_parse_fails(char* text):
	json_value* value = json_parse(text)
	if (value != 0):
		json_free(value)
	assert_equal(0, cast(int, value))


void assert_json_round_trip(char* input, char* want):
	json_value* root = json_parse(input)
	assert1(root != 0)
	char* text = json_stringify(root)
	assert_strings_equal(want, text)
	free(text)
	json_free(root)


void test_build_values():
	json_value* object = json_object()
	json_object_set(object, c"name", json_string(c"w"))
	json_object_set(object, c"answer", json_int(42))
	json_object_set(object, c"ok", json_bool(1))
	assert_equal(1, json_object_has(object, c"name"))
	assert_equal(0, json_object_has(object, c"missing"))
	assert_json_string(json_object_get(object, c"name"), c"w")
	assert_json_int(json_object_get(object, c"answer"), 42)
	json_value* ok = json_object_get(object, c"ok")
	assert_equal(json_type_bool(), ok.type)
	assert_equal(1, ok.int_value)
	json_free(object)


void test_parse_object():
	json_value* root = json_parse(c"{\x22name\x22:\x22w\x22,\x22answer\x22:42,\x22ok\x22:true,\x22nothing\x22:null}")
	assert1(root != 0)
	assert_equal(json_type_object(), root.type)
	assert_json_string(json_object_get(root, c"name"), c"w")
	assert_json_int(json_object_get(root, c"answer"), 42)
	json_value* ok = json_object_get(root, c"ok")
	json_value* nothing = json_object_get(root, c"nothing")
	assert_equal(json_type_bool(), ok.type)
	assert_equal(1, ok.int_value)
	assert_equal(json_type_null(), nothing.type)
	json_free(root)


void test_parse_array_and_escapes():
	json_value* root = json_parse(c"[1,-2,\x22line\x5cnnext\x22,false,null]")
	assert1(root != 0)
	assert_equal(json_type_array(), root.type)
	assert_equal(5, json_array_length(root))
	assert_json_int(json_array_get(root, 0), 1)
	assert_json_int(json_array_get(root, 1), -2)
	assert_json_string(json_array_get(root, 2), c"line\nnext")
	json_value* bool_value = json_array_get(root, 3)
	json_value* null_value = json_array_get(root, 4)
	assert_equal(json_type_bool(), bool_value.type)
	assert_equal(0, bool_value.int_value)
	assert_equal(json_type_null(), null_value.type)
	json_free(root)


void test_stringify_array():
	json_value* array = json_array()
	json_array_push(array, json_string(c"a\nb"))
	json_array_push(array, json_int(-3))
	json_array_push(array, json_bool(1))
	json_array_push(array, json_null())
	char* text = json_stringify(array)
	assert_strings_equal(c"[\x22a\x5cnb\x22,-3,true,null]", text)
	free(text)
	json_free(array)


void test_stringify_object_round_trip():
	json_value* object = json_object()
	json_object_set(object, c"message", json_string(c"hello"))
	json_object_set(object, c"count", json_int(2))
	char* text = json_stringify(object)
	json_value* parsed = json_parse(text)
	assert1(parsed != 0)
	assert_json_string(json_object_get(parsed, c"message"), c"hello")
	assert_json_int(json_object_get(parsed, c"count"), 2)
	free(text)
	json_free(parsed)
	json_free(object)


void test_empty_containers_round_trip():
	assert_json_round_trip(c"{}", c"{}")
	assert_json_round_trip(c"[]", c"[]")


void test_quote_backslash_and_control_round_trip():
	assert_json_round_trip(c"\x22quote \x5c\x22 and slash \x5c\x5c\x22", c"\x22quote \x5c\x22 and slash \x5c\x5c\x22")
	assert_json_round_trip(c"\x22\x5cu0001\x22", c"\x22\x5cu0001\x22")


void test_unicode_ascii_escape():
	json_value* root = json_parse(c"\x22letter \x5cu0041\x22")
	assert1(root != 0)
	assert_json_string(root, c"letter A")
	json_free(root)


void assert_json_parses_string(char* text, char* want):
	json_value* root = json_parse(text)
	assert1(root != 0)
	assert_json_string(root, want)
	json_free(root)


void test_unicode_escape_utf8():
	# 2-, 3-, and 4-byte UTF-8 sequences, upper- and lowercase hex
	assert_json_parses_string(c"\x22\x5cu0080\x22", c"\xc2\x80")
	assert_json_parses_string(c"\x22caf\x5cu00e9\x22", c"caf\xc3\xa9")
	assert_json_parses_string(c"\x22caf\x5cu00E9\x22", c"caf\xc3\xa9")
	assert_json_parses_string(c"\x22\x5cu20ac\x22", c"\xe2\x82\xac")
	assert_json_parses_string(c"\x22\x5cud83d\x5cude00\x22", c"\xf0\x9f\x98\x80")
	assert_json_parses_string(c"\x22\x5cuD834\x5cuDD1E\x22", c"\xf0\x9d\x84\x9e")


void test_unicode_escape_lone_surrogates():
	# Lone or mispaired surrogate halves decode to U+FFFD; a mispaired
	# high surrogate does not consume the escape that follows it
	assert_json_parses_string(c"\x22\x5cud800\x22", c"\xef\xbf\xbd")
	assert_json_parses_string(c"\x22\x5cudc00\x22", c"\xef\xbf\xbd")
	assert_json_parses_string(c"\x22\x5cud800\x5cu0041\x22", c"\xef\xbf\xbdA")
	assert_json_parses_string(c"\x22\x5cud800\x5cud801\x22", c"\xef\xbf\xbd\xef\xbf\xbd")
	assert_json_parses_string(c"\x22\x5cud83dx\x22", c"\xef\xbf\xbdx")


void test_unicode_escape_round_trip():
	# Raw UTF-8 bytes pass through parse and stringify untouched; \uXXXX
	# escapes stringify as the decoded raw bytes
	assert_json_round_trip(c"\x22caf\xc3\xa9\x22", c"\x22caf\xc3\xa9\x22")
	assert_json_round_trip(c"\x22\x5cu20ac\x22", c"\x22\xe2\x82\xac\x22")


void test_unicode_escape_invalid():
	assert_json_parse_fails(c"\x22\x5cu12\x22")
	assert_json_parse_fails(c"\x22\x5cuzzzz\x22")
	assert_json_parse_fails(c"\x22\x5cu123")


void test_duplicate_keys_last_wins():
	json_value* root = json_parse(c"{\x22a\x22:1,\x22a\x22:2}")
	assert1(root != 0)
	assert_json_int(json_object_get(root, c"a"), 2)
	json_free(root)


void test_nesting_depth_limit():
	char* under = json_nested_array_text(json_max_depth())
	json_value* root = json_parse(under)
	assert1(root != 0)
	json_free(root)
	free(under)

	char* over = json_nested_array_text(json_max_depth() + 1)
	assert_json_parse_fails(over)
	free(over)


# Exact bit compare: these cases are chosen so the parser's scaling is
# IEEE-correctly-rounded (one multiply or divide chain on exact values)
void assert_json_float(json_value* value, float want):
	assert_equal(json_type_float(), value.type)
	assert_equal(json_float_bits(want), json_float_bits(value.float_value))


void assert_json_parses_float(char* text, float want):
	json_value* root = json_parse(text)
	assert1(root != 0)
	assert_json_float(root, want)
	json_free(root)


# Relative-error compare for values where repeated scaling may drift a
# few ulps off the correctly rounded float32
void assert_json_float_near(json_value* value, float want):
	assert_equal(json_type_float(), value.type)
	float diff = value.float_value - want
	if (diff < 0.0):
		diff = -diff
	float tolerance = want
	if (tolerance < 0.0):
		tolerance = -tolerance
	assert1(diff <= tolerance / 100000.0)


void test_parse_floats():
	assert_json_parses_float(c"1.5", 1.5)
	assert_json_parses_float(c"-0.25", -0.25)
	assert_json_parses_float(c"0.1", 0.1)
	assert_json_parses_float(c"1e9", 1e9)
	assert_json_parses_float(c"2.5e-1", 0.25)
	assert_json_parses_float(c"1E2", 100.0)
	assert_json_parses_float(c"1e+2", 100.0)

	# zero in float spelling stays a float, whatever the sign
	json_value* zero = json_parse(c"[0.0,0e0,-0.0]")
	assert1(zero != 0)
	int i = 0
	while (i < 3):
		json_value* element = json_array_get(zero, i)
		assert_equal(json_type_float(), element.type)
		assert1(element.float_value == 0.0)
		i = i + 1
	json_free(zero)

	# more mantissa digits than float32 holds still parses
	json_value* root = json_parse(c"12345678901.5")
	assert1(root != 0)
	assert_json_float_near(root, 12345678901.5)
	json_free(root)


void test_float_saturation():
	assert_json_parses_float(c"1e50", 3.4028235e38)
	assert_json_parses_float(c"-1e50", -3.4028235e38)
	assert_json_parses_float(c"1e99999", 3.4028235e38)
	json_value* tiny = json_parse(c"1e-50")
	assert1(tiny != 0)
	assert_equal(json_type_float(), tiny.type)
	assert1(tiny.float_value == 0.0)
	json_free(tiny)


void test_float_stringify():
	assert_json_round_trip(c"[1.5,-0.25,100.0,0.25]", c"[1.5,-0.25,100.0,0.25]")
	assert_json_round_trip(c"1e9", c"1000000000.0")
	assert_json_round_trip(c"3.0", c"3.0")
	assert_json_round_trip(c"0.0", c"0.0")
	assert_json_round_trip(c"0.5", c"0.5")

	# scientific output re-parses to the same value
	json_value* first = json_parse(c"1e20")
	assert1(first != 0)
	char* text = json_stringify(first)
	json_value* second = json_parse(text)
	assert1(second != 0)
	assert_json_float_near(second, first.float_value)
	free(text)
	json_free(first)
	json_free(second)


void test_float_nonfinite_stringify():
	float inf = 3.4028235e38 * 10.0
	json_value* value = json_float(inf)
	char* text = json_stringify(value)
	assert_strings_equal(c"null", text)
	free(text)
	json_free(value)


void test_mixed_number_types():
	json_value* root = json_parse(c"{\x22n\x22:1,\x22x\x22:2.5}")
	assert1(root != 0)
	assert_json_int(json_object_get(root, c"n"), 1)
	assert_json_float(json_object_get(root, c"x"), 2.5)
	json_free(root)


void test_number_limit():
	json_value* root = json_parse(c"2147483647")
	assert1(root != 0)
	assert_json_int(root, 2147483647)
	json_free(root)

	# -2^31 is exact on every target (saturation on the 32-bit target,
	# plain accumulation on x64 where int is wider)
	root = json_parse(c"-2147483648")
	assert1(root != 0)
	assert_json_int(root, 0 - 2147483647 - 1)
	json_free(root)


void test_int_saturation():
	# overflow saturates to the native int range instead of failing:
	# int32 on the 32-bit target, int64 on x64
	json_value* root = json_parse(c"99999999999999999999999999")
	assert1(root != 0)
	assert_json_int(root, json_int_max())
	json_free(root)

	root = json_parse(c"-99999999999999999999999999")
	assert1(root != 0)
	assert_json_int(root, json_int_min())
	json_free(root)

	# one past int32: saturated on the 32-bit target, exact on x64
	root = json_parse(c"2147483648")
	assert1(root != 0)
	int want = 2147483647
	if (json_int_max() > want):
		want = want + 1
	assert_json_int(root, want)
	json_free(root)


void test_invalid_inputs():
	assert_json_parse_fails(c"")
	assert_json_parse_fails(c"garbage")
	assert_json_parse_fails(c"null x")
	assert_json_parse_fails(c"\x22abc")
	assert_json_parse_fails(c"[1")
	assert_json_parse_fails(c"{\x22a\x22:1")
	assert_json_parse_fails(c"[1 2]")
	assert_json_parse_fails(c"\x22bad \x5cu escape\x22")
	assert_json_parse_fails(c"[01]")


void test_invalid_number_forms():
	assert_json_parse_fails(c"1.")
	assert_json_parse_fails(c".5")
	assert_json_parse_fails(c"1.e5")
	assert_json_parse_fails(c"1e")
	assert_json_parse_fails(c"1e+")
	assert_json_parse_fails(c"01.5")
	assert_json_parse_fails(c"1e5.5")
	assert_json_parse_fails(c"Infinity")
	assert_json_parse_fails(c"NaN")
