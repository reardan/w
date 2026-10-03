# wbuild: tool=tools/wc2.w
import lib.testing
import lib.file
import lib.process
import structures.json


process_result* wc2_cli_run(char* flag, char* path):
	int count = 1
	if (flag != 0): count = 2
	if (path != 0): count = 3
	char** args = strv_new(count)
	strv_set(args, 0, c"bin/wc2")
	if (flag != 0): strv_set(args, 1, flag)
	if (path != 0): strv_set(args, 2, path)
	process_result* result = process_run(c"bin/wc2", args, 0, 0, 10000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


void test_wc2_cli_dump_and_failures():
	string_builder* path = string_new()
	string_append(path, c"bin/wc2 input \"")
	string_append_int(path, getpid())
	string_append(path, c".w")
	assert1(file_write_text(path.data, c"int main():\n\treturn 2 + 3 * 4\n"))
	process_result* first = wc2_cli_run(c"--dump-ast", path.data)
	assert_equal(0, first.status)
	assert_strings_equal(c"", first.stderr_text)
	json_value* parsed = json_parse(first.stdout_text)
	assert1(parsed != 0)
	assert_equal(1, json_object_get(parsed, c"schema").int_value)
	assert_strings_equal(path.data, json_object_get(parsed, c"file").string_value)
	assert_contains(first.stdout_text, c"\"kind\":\"binary\",\"text\":\"+\"")
	json_free(parsed)
	process_result* second = wc2_cli_run(c"--dump-ast", path.data)
	assert_equal(0, second.status)
	assert_strings_equal(first.stdout_text, second.stdout_text)
	process_result_free(first)
	process_result_free(second)

	assert1(file_write_text(path.data, c"int main(): return 1.5\n"))
	process_result* failed = wc2_cli_run(c"--dump-ast", path.data)
	assert_equal(1, failed.status)
	assert_strings_equal(c"", failed.stdout_text)
	assert_contains(failed.stderr_text, c":1:20: wc2: expected an integer literal")
	process_result_free(failed)
	unlink(path.data)
	failed = wc2_cli_run(c"--dump-ast", path.data)
	assert_equal(1, failed.status)
	assert_contains(failed.stderr_text, c"wc2: cannot read")
	assert_strings_equal(c"", failed.stdout_text)
	process_result_free(failed)
	string_free(path)

	failed = wc2_cli_run(0, 0)
	assert_equal(2, failed.status)
	assert_contains(failed.stderr_text, c"usage: wc2 --dump-ast file.w")
	process_result_free(failed)
	failed = wc2_cli_run(c"--dump-ast", 0)
	assert_equal(2, failed.status)
	process_result_free(failed)
	failed = wc2_cli_run(c"--unknown", c"unused.w")
	assert_equal(2, failed.status)
	process_result_free(failed)
