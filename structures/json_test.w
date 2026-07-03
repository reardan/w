import lib.testing
import structures.json


void assert_json_string(json_value* value, char* want):
	assert_equal(json_type_string(), value.type)
	assert_strings_equal(want, value.string_value)


void assert_json_int(json_value* value, int want):
	assert_equal(json_type_int(), value.type)
	assert_equal(want, value.int_value)


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


void test_invalid_inputs():
	assert_equal(0, json_parse("{\x22bad\x22:1.5}"))
	assert_equal(0, json_parse("\x22bad \x5cu escape\x22"))
	assert_equal(0, json_parse("[01]"))
