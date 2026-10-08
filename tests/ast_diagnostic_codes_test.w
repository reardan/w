# wbuild: target=ast_diagnostic_codes_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/ast_diagnostic_codes_test.w -o bin/ast_diagnostic_codes_test"
# wbuild: step="bin/ast_diagnostic_codes_test"
/*
AST completion plan unit C3.2: 'w check --json' records carry a stable
"code" (the table in compiler/diagnostics.w), an "end_line"/
"end_column" closing the reported token's span, and a "related" array
pointing at the declaration a diagnostic is about. Pins all three for
"Cannot find symbol", the redefinitions and the type mismatches, in the
streaming and the AST-required front ends, and checks that the
human-readable output gains none of them.
*/
import lib.testing
import lib.process
import lib.file
import lib.utf8
import tools.manifest_json


int diag_codes_serial


char* diag_codes_write(char* text):
	diag_codes_serial = diag_codes_serial + 1
	char* path = cstr(f"bin/ast_diagnostic_codes_{getpid()}_{diag_codes_serial}.w")
	assert1(file_write_text(path, text))
	return path


# Runs 'bin/wv2 check --json --quiet [flag] path' and returns its stdout.
char* diag_codes_check(char* path, char* flag, int want_status):
	char** args = strv_new(6)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--json")
	strv_set(args, 3, c"--quiet")
	int at = 4
	if (flag != 0):
		strv_set(args, at, flag)
		at = at + 1
	strv_set(args, at, path)
	process_result* result = process_run(args[0], args, 0, 0, 60000)
	free(cast(void*, args))
	assert1(result != 0)
	assert_equal(want_status, result.status)
	assert_strings_equal(c"", result.stderr_text)
	char* out = strclone(result.stdout_text)
	process_result_free(result)
	return out


# The index-th NDJSON record of text, parsed.
json_value* diag_codes_record(char* text, int index):
	char* line = text
	int seen = 0
	while (line[0]):
		int length = 0
		while ((line[length] != 0) && (line[length] != 10)): length = length + 1
		if (seen == index):
			char* one = cast(char*, malloc(length + 1))
			for i in range(length): one[i] = line[i]
			one[length] = 0
			json_value* row = json_parse(one)
			free(one)
			assert1(row != 0)
			return row
		seen = seen + 1
		if (line[length] == 0): break
		line = line + length + 1
	assert1(0)
	return 0


int diag_codes_count(char* text):
	int count = 0
	int i = 0
	while (text[i]):
		if (text[i] == 10): count = count + 1
		i = i + 1
	return count


void diag_codes_expect_span(json_value* row, char* code, int line, int column, int end_line, int end_column):
	assert_strings_equal(code, jfield_string(row, c"code"))
	assert_equal(line, jfield_int(row, c"line", -1))
	assert_equal(column, jfield_int(row, c"column", -1))
	assert_equal(end_line, jfield_int(row, c"end_line", -1))
	assert_equal(end_column, jfield_int(row, c"end_column", -1))


# The record has exactly one related note, in the record's own file.
void diag_codes_expect_related(json_value* row, int line, int column, char* message):
	json_value* related = jfield_array(row, c"related")
	assert1(related != 0)
	assert_equal(1, json_array_length(related))
	json_value* note = json_array_get(related, 0)
	assert_strings_equal(jfield_string(row, c"file"), jfield_string(note, c"file"))
	assert_equal(line, jfield_int(note, c"line", -1))
	assert_equal(column, jfield_int(note, c"column", -1))
	assert_strings_equal(message, jfield_string(note, c"message"))


void diag_codes_expect_no_related(json_value* row):
	json_value* related = jfield_array(row, c"related")
	assert1(related != 0)
	assert_equal(0, json_array_length(related))


# Mode 0 is the streaming front end (--streaming since the AST default,
# P1.4), mode 1 the given AST flag.
char* diag_codes_mode(int m, char* ast_flag):
	if (m == 0): return c"--streaming"
	return ast_flag


void diag_codes_cleanup(char* path):
	unlink(path)
	free(path)


void test_cannot_find_symbol():
	char* path = diag_codes_write(c"int counter = 0\n\n\nint main():\n\treturn countr + 1\n")
	for m in range(2):
		char* out = diag_codes_check(path, diag_codes_mode(m, c"--ast-full-expressions"), 1)
		assert_equal(1, diag_codes_count(out))
		json_value* row = diag_codes_record(out, 0)
		assert_strings_equal(c"Cannot find symbol: 'countr'", jfield_string(row, c"message"))
		diag_codes_expect_span(row, c"W0001", 5, 9, 5, 15)
		diag_codes_expect_related(row, 1, 5, c"'counter' is declared here")
		json_free(row)
		free(out)
	diag_codes_cleanup(path)


# The span counts codepoints like "column", not bytes.
void test_cannot_find_symbol_utf8_span():
	char* path = diag_codes_write(c"int main():\n\tint x = 1\n\treturn x + \xc3\xb1ame\n")
	char* out = diag_codes_check(path, 0, 1)
	json_value* row = diag_codes_record(out, 0)
	diag_codes_expect_span(row, c"W0001", 3, 13, 3, 17)
	diag_codes_expect_no_related(row)
	json_free(row)
	free(out)
	diag_codes_cleanup(path)


void test_declared_later():
	char* path = diag_codes_write(c"int main():\n\treturn later(1)\n\n# not here: later(\nint   later(int x):\n\treturn x\n")
	char* out = diag_codes_check(path, 0, 1)
	json_value* row = diag_codes_record(out, 0)
	diag_codes_expect_span(row, c"W0001", 2, 9, 2, 14)
	diag_codes_expect_related(row, 5, 7, c"'later' is defined here")
	json_free(row)
	free(out)
	diag_codes_cleanup(path)


void test_symbol_redefined():
	char* path = diag_codes_write(c"int f(int a):\n\treturn a\n\n\nint f(int b):\n\treturn b\n\nint main():\n\treturn 0\n")
	for m in range(2):
		char* out = diag_codes_check(path, diag_codes_mode(m, c"--ast-required"), 1)
		json_value* row = diag_codes_record(out, 0)
		assert_strings_equal(c"symbol redefined: 'f'", jfield_string(row, c"message"))
		diag_codes_expect_span(row, c"W0002", 5, 13, 5, 14)
		diag_codes_expect_related(row, 1, 5, c"previous definition of 'f' is here")
		json_free(row)
		free(out)
	diag_codes_cleanup(path)


# ':=' locals are declared after their initializer; the note still names
# the first declaration's own position.
void test_inferred_redeclaration():
	char* path = diag_codes_write(c"int main():\n\tint y = 0\n\tx := y + 1\n\tx := 2\n\treturn x\n")
	for m in range(2):
		char* out = diag_codes_check(path, diag_codes_mode(m, c"--ast-required"), 1)
		json_value* row = diag_codes_record(out, 0)
		diag_codes_expect_span(row, c"W0008", 4, 7, 4, 8)
		diag_codes_expect_related(row, 3, 2, c"'x' is declared here")
		json_free(row)
		free(out)
	diag_codes_cleanup(path)


void test_generic_redefined():
	char* path = diag_codes_write(c"T first[T](T a):\n\treturn a\n\nT first[T](T b):\n\treturn b\n\nint main():\n\treturn 0\n")
	char* out = diag_codes_check(path, 0, 1)
	json_value* row = diag_codes_record(out, 0)
	assert_strings_equal(c"generic 'first' redefined", jfield_string(row, c"message"))
	assert_strings_equal(c"W0009", jfield_string(row, c"code"))
	diag_codes_expect_related(row, 1, 1, c"previous definition of generic 'first' is here")
	json_free(row)
	free(out)
	diag_codes_cleanup(path)


void test_argument_type_mismatch():
	char* path = diag_codes_write(c"int takes(char* s):\n\treturn 0\n\n\nint main():\n\tint* p = 0\n\ttakes(p)\n\treturn 0\n")
	for m in range(2):
		char* out = diag_codes_check(path, diag_codes_mode(m, c"--ast-required"), 0)
		assert_equal(1, diag_codes_count(out))
		json_value* row = diag_codes_record(out, 0)
		assert_strings_equal(c"function 'takes' argument 1 type mismatch: expected 'char*', got 'int*'", jfield_string(row, c"message"))
		diag_codes_expect_span(row, c"W0004", 7, 9, 7, 10)
		diag_codes_expect_related(row, 1, 5, c"function 'takes' is declared here")
		json_free(row)
		free(out)
	diag_codes_cleanup(path)


void test_return_and_assignment_mismatch():
	char* path = diag_codes_write(c"char* name():\n\tint* p = 0\n\treturn p\n\nint main():\n\tchar* s = 0\n\tint* q = 0\n\ts = q\n\treturn 0\n")
	for m in range(2):
		char* out = diag_codes_check(path, diag_codes_mode(m, c"--ast-required"), 0)
		assert_equal(2, diag_codes_count(out))
		json_value* returned = diag_codes_record(out, 0)
		assert_strings_equal(c"return type mismatch: expected 'char*', got 'int*'", jfield_string(returned, c"message"))
		assert_strings_equal(c"W0003", jfield_string(returned, c"code"))
		diag_codes_expect_related(returned, 1, 7, c"function 'name' is declared here")
		json_free(returned)
		# No declaration to point at: the note list is empty, not stale.
		json_value* assigned = diag_codes_record(out, 1)
		assert_strings_equal(c"assignment type mismatch: expected 'char*', got 'int*'", jfield_string(assigned, c"message"))
		assert_strings_equal(c"W0003", jfield_string(assigned, c"code"))
		diag_codes_expect_no_related(assigned)
		json_free(assigned)
		free(out)
	diag_codes_cleanup(path)


# The more specific "at least" message gets its own code even though
# the general arity pattern matches it too. Arity warnings carry no
# note: the AST-mode replay has no callee symbol, and the two front
# ends must stay record-for-record identical (ast_expression_test).
# --ast-required does not take W variadic calls yet, so the AST run
# here is --ast-full-expressions.
void test_arity_codes():
	char* path = diag_codes_write(c"int two(int a, int b):\n\treturn a + b\n\nint many(int a, int... rest):\n\treturn a\n\nint main():\n\ttwo(1)\n\tmany()\n\treturn 0\n")
	for m in range(2):
		char* out = diag_codes_check(path, diag_codes_mode(m, c"--ast-full-expressions"), 1)
		assert_equal(2, diag_codes_count(out))
		json_value* first = diag_codes_record(out, 0)
		assert_strings_equal(c"W0005", jfield_string(first, c"code"))
		diag_codes_expect_no_related(first)
		json_free(first)
		json_value* second = diag_codes_record(out, 1)
		assert_strings_equal(c"W0006", jfield_string(second, c"code"))
		diag_codes_expect_no_related(second)
		json_free(second)
		free(out)
	diag_codes_cleanup(path)


# Issue #532's warnings (grammar/type_check.w) have their own codes, and
# the AST-required front end replays them with the streaming spans: the
# narrowed literal, the enum literal, the struct operator, the 'case'
# and 'return' keywords and the function's name position.
void test_unsafe_conversion_codes():
	char* path = diag_codes_write(c"enum color:\n\tred\n\nstruct point:\n\tint x\n\nint falls_off(int x):\n\tif (x): return 1\n\nvoid none():\n\treturn 5\n\nint main():\n\tchar c = 300\n\tcolor k = 5\n\tpoint a\n\tpoint b\n\tint same = a == b\n\tswitch same:\n\t\tcase 1:\n\t\t\tpass\n\t\tcase 1:\n\t\t\tpass\n\treturn 0\n")
	for m in range(2):
		char* out = diag_codes_check(path, diag_codes_mode(m, c"--ast-required"), 1)
		assert_equal(6, diag_codes_count(out))
		json_value* row = diag_codes_record(out, 0)
		diag_codes_expect_span(row, c"W0403", 7, 15, 7, 15)
		json_free(row)
		row = diag_codes_record(out, 1)
		diag_codes_expect_span(row, c"W0405", 11, 2, 11, 8)
		json_free(row)
		row = diag_codes_record(out, 2)
		diag_codes_expect_span(row, c"W0400", 14, 11, 14, 14)
		json_free(row)
		row = diag_codes_record(out, 3)
		diag_codes_expect_span(row, c"W0401", 15, 12, 15, 13)
		json_free(row)
		row = diag_codes_record(out, 4)
		diag_codes_expect_span(row, c"W0402", 18, 15, 18, 17)
		json_free(row)
		row = diag_codes_record(out, 5)
		diag_codes_expect_span(row, c"W0404", 22, 8, 22, 8)
		json_free(row)
		free(out)
	diag_codes_cleanup(path)


# A lint finding names no token: its span is zero-width.
void test_lint_zero_width_span():
	char* path = diag_codes_write(c"int main():\n\tint unused = 1\n\treturn 0\n")
	char* out = diag_codes_check(path, c"--lint", 0)
	json_value* row = diag_codes_record(out, 0)
	assert_strings_equal(c"W0091", jfield_string(row, c"code"))
	assert_equal(jfield_int(row, c"line", -1), jfield_int(row, c"end_line", -2))
	assert_equal(jfield_int(row, c"column", -1), jfield_int(row, c"end_column", -2))
	diag_codes_expect_no_related(row)
	json_free(row)
	free(out)
	diag_codes_cleanup(path)


# --all-errors reports each error from its own probe: every record gets
# its own note and none leaks into the next one.
void test_all_errors_notes_do_not_leak():
	char* path = diag_codes_write(c"int value = 1\nint first():\n\treturn valeu\nint second():\n\treturn nothing_like_it\nint main():\n\treturn 0\n")
	char* out = diag_codes_check(path, c"--all-errors", 1)
	assert_equal(2, diag_codes_count(out))
	json_value* first = diag_codes_record(out, 0)
	diag_codes_expect_span(first, c"W0001", 3, 9, 3, 14)
	diag_codes_expect_related(first, 1, 5, c"'value' is declared here")
	json_free(first)
	json_value* second = diag_codes_record(out, 1)
	assert_strings_equal(c"W0001", jfield_string(second, c"code"))
	diag_codes_expect_no_related(second)
	json_free(second)
	free(out)
	diag_codes_cleanup(path)


# Human-readable diagnostics are unchanged: no code, span or note.
void test_human_output_has_no_json_fields():
	char* path = diag_codes_write(c"int f(int a):\n\treturn a\nint f(int b):\n\treturn b\n")
	char** args = strv_new(4)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--quiet")
	strv_set(args, 3, path)
	process_result* result = process_run(args[0], args, 0, 0, 60000)
	free(cast(void*, args))
	assert_equal(1, result.status)
	assert_strings_equal(c"", result.stdout_text)
	assert_contains(result.stderr_text, c"error: symbol redefined: 'f'")
	assert_lacks(result.stderr_text, c"W0002")
	assert_lacks(result.stderr_text, c"previous definition")
	process_result_free(result)
	diag_codes_cleanup(path)


# A command-line diagnostic has no source position: zero span, no note.
void test_command_line_record():
	char* path = diag_codes_write(c"int main():\n\treturn 0\n")
	char* out = diag_codes_check(path, c"--no-such-option", 1)
	json_value* row = diag_codes_record(out, 0)
	assert_strings_equal(c"<command-line>", jfield_string(row, c"file"))
	diag_codes_expect_span(row, c"W0384", 0, 0, 0, 0)
	diag_codes_expect_no_related(row)
	json_free(row)
	free(out)
	diag_codes_cleanup(path)
