import lib.testing
import structures.json
import structures.string


void assert_json_string(json_value* value, char* want):
	assert_equal(json_type_string(), value.type)
	assert_strings_equal(want, value.string_value)


void assert_json_int(json_value* value, int want):
	assert_equal(json_type_int(), value.type)
	assert_equal(want, value.int_value)


char* json_test_take_string_data(string* s):
	char* data = s.data
	free(s)
	return data


char* json_nested_array_text(int depth):
	string* s = string_new()
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
	json_object_set(object, "name", json_string("w"))
	json_object_set(object, "answer", json_int(42))
	json_object_set(object, "ok", json_bool(1))
	assert_equal(1, json_object_has(object, "name"))
	assert_equal(0, json_object_has(object, "missing"))
	assert_json_string(json_object_get(object, "name"), "w")
	assert_json_int(json_object_get(object, "answer"), 42)
	json_value* ok = json_object_get(object, "ok")
	assert_equal(json_type_bool(), ok.type)
	assert_equal(1, ok.int_value)
	json_free(object)


void test_parse_object():
	json_value* root = json_parse("{\x22name\x22:\x22w\x22,\x22answer\x22:42,\x22ok\x22:true,\x22nothing\x22:null}")
	assert1(root != 0)
	assert_equal(json_type_object(), root.type)
	assert_json_string(json_object_get(root, "name"), "w")
	assert_json_int(json_object_get(root, "answer"), 42)
	json_value* ok = json_object_get(root, "ok")
	json_value* nothing = json_object_get(root, "nothing")
	assert_equal(json_type_bool(), ok.type)
	assert_equal(1, ok.int_value)
	assert_equal(json_type_null(), nothing.type)
	json_free(root)


void test_parse_array_and_escapes():
	json_value* root = json_parse("[1,-2,\x22line\x5cnnext\x22,false,null]")
	assert1(root != 0)
	assert_equal(json_type_array(), root.type)
	assert_equal(5, json_array_length(root))
	assert_json_int(json_array_get(root, 0), 1)
	assert_json_int(json_array_get(root, 1), -2)
	assert_json_string(json_array_get(root, 2), "line\nnext")
	json_value* bool_value = json_array_get(root, 3)
	json_value* null_value = json_array_get(root, 4)
	assert_equal(json_type_bool(), bool_value.type)
	assert_equal(0, bool_value.int_value)
	assert_equal(json_type_null(), null_value.type)
	json_free(root)


void test_stringify_array():
	json_value* array = json_array()
	json_array_push(array, json_string("a\nb"))
	json_array_push(array, json_int(-3))
	json_array_push(array, json_bool(1))
	json_array_push(array, json_null())
	char* text = json_stringify(array)
	assert_strings_equal("[\x22a\x5cnb\x22,-3,true,null]", text)
	free(text)
	json_free(array)


void test_stringify_object_round_trip():
	json_value* object = json_object()
	json_object_set(object, "message", json_string("hello"))
	json_object_set(object, "count", json_int(2))
	char* text = json_stringify(object)
	json_value* parsed = json_parse(text)
	assert1(parsed != 0)
	assert_json_string(json_object_get(parsed, "message"), "hello")
	assert_json_int(json_object_get(parsed, "count"), 2)
	free(text)
	json_free(parsed)
	json_free(object)


void test_empty_containers_round_trip():
	assert_json_round_trip("{}", "{}")
	assert_json_round_trip("[]", "[]")


void test_quote_backslash_and_control_round_trip():
	assert_json_round_trip("\x22quote \x5c\x22 and slash \x5c\x5c\x22", "\x22quote \x5c\x22 and slash \x5c\x5c\x22")
	assert_json_round_trip("\x22\x5cu0001\x22", "\x22\x5cu0001\x22")


void test_unicode_ascii_escape():
	json_value* root = json_parse("\x22letter \x5cu0041\x22")
	assert1(root != 0)
	assert_json_string(root, "letter A")
	json_free(root)
	assert_json_parse_fails("\x22\x5cu0080\x22")


void test_duplicate_keys_last_wins():
	json_value* root = json_parse("{\x22a\x22:1,\x22a\x22:2}")
	assert1(root != 0)
	assert_json_int(json_object_get(root, "a"), 2)
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
	json_value* root = json_parse("2147483647")
	assert1(root != 0)
	assert_json_int(root, 2147483647)
	json_free(root)
	assert_json_parse_fails("2147483648")
	assert_json_parse_fails("9999999999")


void test_invalid_inputs():
	assert_json_parse_fails("")
	assert_json_parse_fails("garbage")
	assert_json_parse_fails("null x")
	assert_json_parse_fails("\x22abc")
	assert_json_parse_fails("[1")
	assert_json_parse_fails("{\x22a\x22:1")
	assert_json_parse_fails("[1 2]")
	assert_json_parse_fails("{\x22bad\x22:1.5}")
	assert_json_parse_fails("\x22bad \x5cu escape\x22")
	assert_json_parse_fails("[01]")
