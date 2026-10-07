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
	# Exercise the in-process recovery (repl_setjmp/repl_longjmp state) on
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
	# Cross several getchar refill windows inside one function. Recovery
	# returns the lexer to a statement's start; a clean file must not be
	# disturbed by the boundaries it never uses.
	char* text = cast(char*, malloc(30000))
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
	# The 100 source errors plus one limit diagnostic. In particular the
	# limit reached inside a nested boundary must end the whole check, not
	# restart recovery in an enclosing one.
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
	# earlier semantic error instead of recovering at the same EOF again.
	assert_equal(2, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_contains(result.stdout_text, c"missing_before_eof")
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


process_result* analysis_test_run_args(char* path, char* first, char* second):
	char** args = strv_new(9)
	strv_set(args, 0, c"bin/wv2")
	if (__word_size__ == 8): strv_set(args, 0, c"bin/wv2_64")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--json")
	strv_set(args, 3, c"--quiet")
	strv_set(args, 4, c"--all-errors")
	strv_set(args, 5, first)
	strv_set(args, 6, second)
	strv_set(args, 7, path)
	process_result* result = process_run(args[0], args, 0, 0, 30000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


int analysis_test_count(char* text, char* needle):
	int count = 0
	int at = 0
	int length = strlen(needle)
	while (text[at]):
		int matched = 0
		while ((matched < length) && (text[at + matched] == needle[matched])): matched = matched + 1
		if (matched == length): count = count + 1
		at = at + 1
	return count


# A failed declaration keeps the binding it had already made: the typed
# local whose initializer failed, the function whose parameter type or
# body failed. Their later uses resolve instead of each adding a follow-on
# "Cannot find symbol" (the fork-based checker discarded them).
void test_analysis_failed_bindings_stay_visible():
	char* path = cstr(f"bin/analysis_poison_{getpid()}.w")
	assert1(file_write_text(path, c"int takes(UnknownParam p, int q):\n\treturn q\nint body_fails(int q):\n\tmissing_in_body()\n\treturn q\nint main():\n\tint local = missing_initializer()\n\tint sum = local + takes(0, 1) + body_fails(2)\n\treturn sum + local\n"))
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	assert_equal(3, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_contains(result.stdout_text, c"UnknownParam")
	assert_contains(result.stdout_text, c"missing_in_body")
	assert_contains(result.stdout_text, c"missing_initializer")
	assert_equal(0, analysis_test_count(result.stdout_text, c"'local'"))
	assert_equal(0, analysis_test_count(result.stdout_text, c"'takes'"))
	assert_equal(0, analysis_test_count(result.stdout_text, c"'body_fails'"))
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


# Warnings are reported as the parse meets them, including those of a
# function with errors, and a failed final statement does not add a
# missing-return warning: the function warns exactly as plain check does
# up to its first error.
void test_analysis_warnings_beside_errors():
	char* path = cstr(f"bin/analysis_warnings_{getpid()}.w")
	assert1(file_write_text(path, c"int warns(int* value):\n\tchar* text = value\n\tmissing_after_warning()\n\treturn missing_in_return()\nint main():\n\treturn warns(0)\n"))
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	assert_contains(result.stdout_text, c"initialization type mismatch")
	assert_equal(1, analysis_test_count(result.stdout_text, c"\"severity\": \"warning\""))
	assert_equal(2, analysis_test_count(result.stdout_text, c"\"severity\": \"error\""))
	assert_equal(0, analysis_test_count(result.stdout_text, c"without returning a value"))
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


# A failed nested if skips its own else/elif arms, but not those of the
# enclosing if at a shallower indentation.
void test_analysis_enclosing_else_kept():
	char* path = cstr(f"bin/analysis_else_{getpid()}.w")
	assert1(file_write_text(path, c"int classify(int value):\n\tif value < 0:\n\t\tif missing_inner < -5: return -2\n\t\telse: return -1\n\telif value == 0: return missing_in_elif\n\telse:\n\t\treturn 1\nint main():\n\treturn classify(0)\n"))
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	assert_equal(2, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_contains(result.stdout_text, c"missing_inner")
	assert_contains(result.stdout_text, c"missing_in_elif")
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


# An unterminated literal ends the input: it is reported once, after the
# errors before it, not again by the skip that would re-read it.
void test_analysis_unterminated_literal_once():
	char* path = cstr(f"bin/analysis_literal_{getpid()}.w")
	assert1(file_write_text(path, c"int main():\n\tmissing_before_literal()\n\tchar* text = c\"open\n\treturn 0\n"))
	process_result* result = analysis_test_run(path, 1)
	assert_equal(1, result.status)
	assert_equal(2, analysis_test_diagnostics(result.stdout_text, c"error"))
	assert_equal(1, analysis_test_count(result.stdout_text, c"unterminated string literal"))
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)


# Recovery inside blocks whose statements the retained walk emits after
# their parse: the failed statement's walk record must not block the
# enclosing block's later phases.
void test_analysis_retained_walk_recovery():
	char* path = cstr(f"bin/analysis_walk_{getpid()}.w")
	# Each failing if is its block's last statement: the block's end phase
	# is recorded right after the failed walk.
	assert1(file_write_text(path, c"int walked(int n):\n\tint total = 0\n\tfor i in range(n):\n\t\ttotal = total + i\n\t\tif missing_in_loop > 2:\n\t\t\ttotal = 0\n\twhile total > 10:\n\t\ttotal = total - 1\n\t\tif total == missing_in_while: total = 0\n\treturn total\nint main():\n\treturn walked(5)\n"))
	process_result* result = analysis_test_run_args(path, c"--ast-required", c"--ast-emit-retained")
	assert_equal(1, result.status)
	assert_equal(2, analysis_test_diagnostics(result.stdout_text, c"error"))
	# Required mode reports an unresolved name as an unsupported
	# expression, so the lines identify the two.
	assert_contains(result.stdout_text, c"\"line\": 5,")
	assert_contains(result.stdout_text, c"\"line\": 9,")
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)
