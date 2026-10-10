import lib.testing
import lib.file
import lib.process


process_result* fixture_ast_run(int ast, char* first, char* second, char* third):
	char** args = strv_new(6)
	strv_set(args, 0, c"bin/wfixture")
	int i = 1
	if (ast):
		strv_set(args, i, c"--ast-expressions")
		i = i + 1
	strv_set(args, i, c"bin/wv2")
	i = i + 1
	strv_set(args, i, first)
	i = i + 1
	if (second):
		strv_set(args, i, second)
		i = i + 1
	if (third): strv_set(args, i, third)
	process_result* result = process_run(args[0], args, 0, 0, 30000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


void test_fixture_ast_mode_preserves_diagnostics():
	process_result* result = fixture_ast_run(1, c"tests/limb_builtin_warning_fixture.w", c"tests/expression_nesting_clean_fixture.w", c"tests/expression_nesting_error_fixture.w")
	assert_equal(0, result.status)
	assert_contains(result.stdout_text, c"--ast-full-expressions tests/limb_builtin_warning_fixture.w")
	assert_contains(result.stdout_text, c"--ast-required tests/expression_nesting_clean_fixture.w")
	assert_contains(result.stdout_text, c"--ast-full-expressions tests/expression_nesting_error_fixture.w")
	assert_contains(result.stdout_text, c"wfixture: OK (3 fixtures)")
	process_result_free(result)


void test_fixture_ast_mode_preserves_selector():
	process_result* result = fixture_ast_run(1, c"tests/atomic_host_operand_error_fixture.w", 0, 0)
	assert_equal(0, result.status)
	assert_contains(result.stdout_text, c"--ast-required x64 tests/atomic_host_operand_error_fixture.w")
	process_result_free(result)


void test_fixture_ast_mode_enforces_positive_coverage():
	string_builder* name = string_from(c"bin/wfixture_ast_unsupported_")
	string_append_int(name, getpid())
	char* output = strclone(name.data)
	string_append(name, c".w")
	# Inference through a generic record parameter still needs the
	# streaming header replay. This is a semantic coverage gap, not an
	# expression-size limit: ordinary compilation accepts the fallback,
	# while the fixture runner must require positive AST coverage.
	char* source = c"# reject_stderr: error\nstruct CoverageBox[T]:\n\tT value\nint read_box[T](CoverageBox[T]* box, T hint): return box.value + cast(int, hint)\nint main():\n\tCoverageBox[int] box\n\tbox.value = 1\n\treturn read_box(&box, 2)\n"
	assert1(file_write_text(name.data, source))
	process_result* plain = fixture_ast_run(0, name.data, 0, 0)
	assert_equal(0, plain.status)
	process_result_free(plain)
	process_result* ast = fixture_ast_run(1, name.data, 0, 0)
	assert_equal(1, ast.status)
	assert_contains(ast.stderr_text, c"AST-required compilation encountered an unsupported expression")
	process_result_free(ast)
	unlink(name.data)
	unlink(output)
	string_free(name)
	free(output)


void test_fixture_ast_mode_keeps_explicit_frontends():
	string_builder* name = string_from(c"bin/wfixture_ast_explicit_")
	string_append_int(name, getpid())
	char* output = strclone(name.data)
	string_append(name, c".w")
	char* path = strclone(name.data)
	string_free(name)
	char*[7] modes
	modes[0] = c"--streaming"
	modes[1] = c"--ast-full-expressions"
	modes[2] = c"--ast-expressions"
	modes[3] = c"--ast-required"
	modes[4] = c"--ast-retain"
	modes[5] = c"--ast-emit-retained"
	modes[6] = c"--ast-audit"
	for i in range(7):
		string_builder* source = string_from(c"# wfixture: ")
		string_append(source, modes[i])
		string_append(source, c"\n# reject_stderr: error\nint main():\n\treturn 0\n")
		assert1(file_write_text(path, source.data))
		string_free(source)
		process_result* result = fixture_ast_run(1, path, 0, 0)
		assert_equal(0, result.status)
		string_builder* command = string_from(c"$ bin/wv2 ")
		string_append(command, modes[i])
		string_append(command, c" ")
		string_append(command, path)
		string_append(command, c" -o ")
		string_append(command, output)
		assert_contains(result.stdout_text, command.data)
		assert_contains(result.stdout_text, c"wfixture: OK (1 fixtures)")
		string_free(command)
		process_result_free(result)
	unlink(path)
	unlink(output)
	free(path)
	free(output)


void test_fixture_ast_mode_keeps_explicit_diagnostic_frontends():
	process_result* result = fixture_ast_run(1, c"tests/diagnostic_sites/shift_streaming_error_fixture.w", c"tests/diagnostic_sites/ternarr_warning_fixture.w", 0)
	assert_equal(0, result.status)
	assert_contains(result.stdout_text, c"$ bin/wv2 --streaming tests/diagnostic_sites/shift_streaming_error_fixture.w")
	assert_contains(result.stdout_text, c"$ bin/wv2 --ast-full-expressions tests/diagnostic_sites/ternarr_warning_fixture.w")
	assert_contains(result.stdout_text, c"wfixture: OK (2 fixtures)")
	process_result_free(result)


# wbuild: binary=wfixture_ast_test tag=tests dep=wfixture data=tests/atomic_host_operand_error_fixture.w data=tests/limb_builtin_warning_fixture.w data=tests/expression_nesting_clean_fixture.w data=tests/expression_nesting_error_fixture.w data=tests/diagnostic_sites/shift_streaming_error_fixture.w data=tests/diagnostic_sites/ternarr_warning_fixture.w
# wbuild: step="bin/wfixture_ast_test"
