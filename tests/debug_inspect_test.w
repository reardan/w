# wbuild: binary=debug_inspect_test tag=tests dep=wdbg dep=wdbg_x64 data=tests/debug_inspect_fixture.w
# wbuild: step="bin/debug_inspect_test"
import lib.testing
import lib.process
import lib.mem
import lib.str
import structures.json


json_value* inspect_test_reply(char* output, int index):
	int at = 0
	for i in range(index + 1):
		int found = index_of(output + at, c"wdbg-data ")
		assert1(found >= 0)
		at = at + found + 10
		if (i < index):
			while (output[at] && (output[at] != 10)): at = at + 1
	int end = at
	while (output[end] && (output[end] != 10)): end = end + 1
	char* line = mem_dup(output + at, end - at)
	json_value* reply = json_parse(line)
	free(line)
	assert1(reply != 0)
	return reply


char* inspect_test_value(json_value* root):
	return json_object_get(json_object_get(root, c"value"), c"value").string_value


void test_structured_inspection():
	for host in range(2):
		char* binary = c"bin/wdbg"
		if (host): binary = c"bin/wdbg64"
		char** args = strv_new(2)
		strv_set(args, 0, binary)
		strv_set(args, 1, c"tests/debug_inspect_fixture.w")
		process_result* result = process_run(binary, args, 0, c"inspect node\ninspect node.next\ninspect node.next.next.value\ninspect node.pair.negative\ninspect node.pair.small\ninspect nil\ninspect bad.value\ninspect protected.*\ninspect missing\ninspect node.value = 100\ninspect inspect_global\ncontinue\ninspect node.value\ncontinue\n", 30000)
		free(cast(void*, args))
		assert_equal(0, result.status)
		assert_contains(result.stdout_text, c"debuggee main returned 0")
		json_value* root = inspect_test_reply(result.stdout_text, 0)
		json_value* children = json_object_get(root, c"children")
		assert_equal(3, json_array_length(children))
		assert_strings_equal(c"42", json_object_get(json_array_get(children, 0), c"value").string_value)
		assert_strings_equal(c"node.next", json_object_get(json_array_get(children, 1), c"path").string_value)
		json_free(root)
		root = inspect_test_reply(result.stdout_text, 1)
		children = json_object_get(root, c"children")
		assert_strings_equal(c"99", json_object_get(json_array_get(children, 0), c"value").string_value)
		json_free(root)
		char*[3] expected
		expected[0] = c"42"
		expected[1] = c"-7"
		expected[2] = c"255"
		for i in range(3):
			root = inspect_test_reply(result.stdout_text, i + 2)
			assert_strings_equal(expected[i], inspect_test_value(root))
			json_free(root)
		root = inspect_test_reply(result.stdout_text, 5)
		assert_strings_equal(c"Null pointer", json_object_get(root, c"error").string_value)
		json_free(root)
		for i in range(6, 8):
			root = inspect_test_reply(result.stdout_text, i)
			assert_contains(inspect_test_value(root), c"unreadable")
			json_free(root)
		for i in range(8, 10):
			root = inspect_test_reply(result.stdout_text, i)
			assert1(json_object_get(root, c"error") != 0)
			json_free(root)
		root = inspect_test_reply(result.stdout_text, 10)
		assert_strings_equal(c"17", inspect_test_value(root))
		json_free(root)
		root = inspect_test_reply(result.stdout_text, 11)
		assert_strings_equal(c"43", inspect_test_value(root))
		json_free(root)
		process_result_free(result)
