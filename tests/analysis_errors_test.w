# wbuild: target=analysis_errors_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/analysis_errors_test.w -o bin/analysis_errors_test"
# wbuild: step="bin/analysis_errors_test"
# wbuild: target=analysis_errors_64_test tag=tests_x64 dep=build_x64
# wbuild: step="bin/wv2 x64 tests/analysis_errors_test.w -o bin/analysis_errors_64_test"
# wbuild: step="bin/analysis_errors_64_test"
import lib.testing
import lib.process
import lib.file
import lib.utf8
import tools.manifest_json


process_result* analysis_test_run(char* path, int multiple):
	char** args = strv_new(8)
	strv_set(args, 0, c"bin/wv2")
	# Exercise the probe's native fd, wait-status and pipe-word handling on
	# both compiler host widths, independently of the requested x64 target.
	if (__word_size__ == 8): strv_set(args, 0, c"bin/wv2_64")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--json")
	strv_set(args, 3, c"--quiet")
	if (multiple): strv_set(args, 4, c"--all-errors")
	else: strv_set(args, 4, c"--quiet")
	strv_set(args, 5, c"x64")
	strv_set(args, 6, c"--ast-retain")
	strv_set(args, 7, path)
	process_result* result = process_run(args[0], args, 0, 0, 30000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


int analysis_test_diagnostics(char* text, char* severity):
	int count = 0
	char* line = text
	while (line[0]):
		int length = 0
		while ((line[length] != 0) && (line[length] != 10)): length = length + 1
		int ending = line[length]
		line[length] = 0
		json_value* row = json_parse(line)
		assert1(row != 0)
		assert_strings_equal(severity, jfield_string(row, c"severity"))
		assert1(jfield_int(row, c"line", 0) > 0)
		assert1(jfield_int(row, c"column", 0) > 0)
		json_free(row)
		line[length] = ending
		count = count + 1
		if (ending == 0): break
		line = line + length + 1
	return count


void test_independent_semantic_errors():
	char* path = cstr(f"bin/analysis_errors_{getpid()}.w")
	assert1(file_write_text(path, c"int first():\n\tint stable = 3\n\tmissing_one()\n\tint another = stable + 1\n\tmissing_two()\n\treturn another\nint second() {\n\tmissing_three(); missing_four();\n\tif (1) {\n\t\tmissing_five();\n\t\tmissing_six();\n\t}\n\treturn 0;\n}\nint main():\n\treturn 0\n"))
	process_result* first = analysis_test_run(path, 1)
	assert_equal(1, first.status)
	assert_strings_equal(c"", first.stderr_text)
	assert_equal(6, analysis_test_diagnostics(first.stdout_text, c"error"))
	assert_contains(first.stdout_text, c"missing_one")
	assert_contains(first.stdout_text, c"missing_six")
	process_result* repeated = analysis_test_run(path, 1)
	assert_equal(1, repeated.status)
	assert_strings_equal(first.stdout_text, repeated.stdout_text)
	process_result_free(repeated)
	process_result_free(first)
	first = analysis_test_run(path, 0)
	assert_equal(1, first.status)
	assert_equal(1, analysis_test_diagnostics(first.stdout_text, c"error"))
	process_result_free(first)
	unlink(path)
	free(path)


void test_analysis_source_buffer_and_success():
	char* path = cstr(f"bin/analysis_clean_{getpid()}.w")
	# Cross several getchar refill windows during each probe. A fork shares
	# kernel fd positions, and restoring only the lexer offset corrupts replay.
	char* text = malloc(30000)
	int at = 0
	char* header = c"int clean(int input):\n\tint value = input\n"
	for i in range(strlen(header)): text[i] = header[i]
	at = strlen(header)
	char* line = c"\tvalue = value + 1 # a long enough statement to refill source buffers\n"
	for i in range(200):
		for j in range(strlen(line)): text[at + j] = line[j]
		at = at + strlen(line)
	char* ending = c"\treturn value\nint main():\n\treturn clean(0) - 200\n"
	for i in range(strlen(ending) + 1): text[at + i] = ending[i]
	assert1(file_write_text(path, text))
	free(text)
	process_result* result = analysis_test_run(path, 1)
	assert_equal(0, result.status)
	assert_strings_equal(c"", result.stdout_text)
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


void test_analysis_import_boundaries():
	char* path = cstr(f"bin/analysis_import_{getpid()}.w")
	char* module = cstr(f"bin/analysis_dep_{getpid()}.w")
	assert1(file_write_text(module, c"int dependency_good():\n\treturn 4\nint dependency_bad():\n\tmissing_in_dependency_one()\n\tmissing_in_dependency_two()\n\treturn 0\n"))
	char* source = cstr(f"import analysis_dep_{getpid()}\nint main():\n\tint value = dependency_good()\n\tmissing_in_root()\n\treturn value\n")
	assert1(file_write_text(path, source))
	free(source)
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	assert_equal(3, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_contains(result.stdout_text, c"missing_in_dependency_one")
	assert_contains(result.stdout_text, c"missing_in_dependency_two")
	assert_contains(result.stdout_text, c"missing_in_root")
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	unlink(module)
	free(path)
	free(module)


void test_analysis_unmatched_delimiter_progress():
	char* path = cstr(f"bin/analysis_delimiter_{getpid()}.w")
	assert1(file_write_text(path, c"}\nint main():\n\tmissing_after_delimiter()\n\treturn 0\n"))
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	assert_equal(2, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_contains(result.stdout_text, c"missing_after_delimiter")
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


void test_analysis_script_suffix_once():
	char* path = cstr(f"bin/analysis_script_{getpid()}.w")
	assert1(file_write_text(path, c"missing_script_one()\nmissing_script_two()\nmissing_script_three()\n"))
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	assert_equal(3, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_contains(result.stdout_text, c"missing_script_three")
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


void test_analysis_preserves_valid_type_declarations():
	char* path = cstr(f"bin/analysis_types_{getpid()}.w")
	assert1(file_write_text(path, c"struct Good:\n\tint value\nstruct Bad:\n\tUnknownFieldType value\nint read_good(Good* item):\n\treturn item.value\nint independent():\n\treturn missing_after_types\n"))
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	assert_equal(2, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_contains(result.stdout_text, c"UnknownFieldType")
	assert_contains(result.stdout_text, c"missing_after_types")
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


void test_analysis_global_error_limit():
	char* path = cstr(f"bin/analysis_limit_{getpid()}.w")
	string_builder* source = string_new()
	for function_index in range(6):
		string_append(source, c"int failed_")
		string_append_int(source, function_index)
		string_append(source, c"():\n")
		for statement_index in range(25):
			string_append(source, c"\tmissing_many_errors()\n")
		string_append(source, c"\treturn 0\n")
	assert1(file_write_text(path, source.data))
	string_free(source)
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	# The 100 source errors plus one limit diagnostic. In particular a
	# child's limit must terminate its ancestors, not restart recovery.
	assert_equal(101, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_contains(result.stdout_text, c"stopping after 100 semantic errors")
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


void test_analysis_terminal_error_after_recovery():
	char* path = cstr(f"bin/analysis_eof_{getpid()}.w")
	assert1(file_write_text(path, c"int unfinished() {\n\tmissing_before_eof();\n"))
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	# EOF cannot make synchronization progress. Report it once after the
	# earlier semantic error instead of repeatedly probing the same EOF.
	assert_equal(2, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_contains(result.stdout_text, c"missing_before_eof")
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)
