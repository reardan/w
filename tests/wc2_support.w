import lib.testing
import lib.file
import lib.process
import tools.wc2.lower
import tools.wc2.emit


char* wc2_emit_test_path(char* suffix):
	string_builder* path = string_new()
	string_append(path, c"bin/wc2 emit \"")
	string_append_int(path, getpid())
	string_append(path, suffix)
	char* result = strclone(path.data)
	string_free(path)
	return result


process_result* wc2_test_compile(char* compiler, char* source, char* output):
	char** args = strv_new(4)
	strv_set(args, 0, compiler)
	strv_set(args, 1, source)
	strv_set(args, 2, c"-o")
	strv_set(args, 3, output)
	process_result* result = process_run(compiler, args, 0, 0, 10000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


void wc2_test_exit(char* path, int expected):
	char** args = strv_new(1)
	strv_set(args, 0, path)
	process_result* result = process_run(path, args, 0, 0, 10000)
	free(cast(void*, args))
	assert1(result != 0)
	assert_equal(expected, result.status)
	assert_strings_equal(c"", result.stdout_text)
	assert_strings_equal(c"", result.stderr_text)
	process_result_free(result)


void wc2_test_differential(char* expression, char* expected):
	# Compare the entire 32-bit result inside the program, avoiding the
	# eight-bit truncation of process exit codes hiding arithmetic bugs.
	string_builder* source = string_new()
	string_append(source, c"int main(): return (")
	string_append(source, expression)
	string_append(source, c") != (")
	string_append(source, expected)
	string_append(source, c")\n")
	char* input = wc2_emit_test_path(c".w")
	char* output = wc2_emit_test_path(c".elf")
	char* reference = wc2_emit_test_path(c".reference")
	wc2_module* m = wc2_parse(source.data, input)
	asm_buffer* image = wc2_emit(m)
	asserts(expression, image != 0)
	assert1(wc2_write_executable(output, image))
	wc2_test_exit(output, 0)
	assert1(file_write_text(input, source.data))
	process_result* compiled = wc2_test_compile(c"bin/wv2", input, reference)
	asserts(expression, compiled.status == 0)
	process_result_free(compiled)
	wc2_test_exit(reference, 0)
	asm_buffer_free(image)
	wc2_module_free(m)
	string_free(source)
	unlink(input)
	unlink(output)
	unlink(reference)
	free(input)
	free(output)
	free(reference)


void wc2_test_rejected(char* source, char* message):
	wc2_module* m = wc2_parse(source, c"reject.w")
	assert1(wc2_module_ok(m))
	assert1(wc2_emit(m) == 0)
	assert_equal(0, wc2_module_ok(m))
	assert1(m.diagnostics.items.length > 0)
	assert_contains(m.diagnostics.items[0].message, message)
	wc2_module_free(m)
