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
	assert_equal(0, value)


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
	assert_json_parse_fails(c"\x22\x5cu0080\x22")


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


void test_number_limit():
	json_value* root = json_parse(c"2147483647")
	assert1(root != 0)
	assert_json_int(root, 2147483647)
	json_free(root)
	assert_json_parse_fails(c"2147483648")
	assert_json_parse_fails(c"9999999999")


void test_invalid_inputs():
	assert_json_parse_fails(c"")
	assert_json_parse_fails(c"garbage")
	assert_json_parse_fails(c"null x")
	assert_json_parse_fails(c"\x22abc")
	assert_json_parse_fails(c"[1")
	assert_json_parse_fails(c"{\x22a\x22:1")
	assert_json_parse_fails(c"[1 2]")
	assert_json_parse_fails(c"{\x22bad\x22:1.5}")
	assert_json_parse_fails(c"\x22bad \x5cu escape\x22")
	assert_json_parse_fails(c"[01]")
