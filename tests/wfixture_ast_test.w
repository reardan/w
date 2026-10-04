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
	assert_contains(result.stdout_text, c"--ast-required tests/limb_builtin_warning_fixture.w")
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
	string_builder* name = string_from(c"bin/wfixture_ast_capacity_")
	string_append_int(name, getpid())
	char* output = strclone(name.data)
	string_append(name, c".w")
	string_builder* source = string_from(c"# reject_stderr: error\nint main(): return ")
	for i in range(2300): string_append(source, c"1+")
	string_append(source, c"1\n")
	assert1(file_write_text(name.data, source.data))
	string_free(source)
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


# wbuild: binary=wfixture_ast_test tag=tests dep=wfixture data=tests/atomic_host_operand_error_fixture.w data=tests/limb_builtin_warning_fixture.w data=tests/expression_nesting_clean_fixture.w data=tests/expression_nesting_error_fixture.w
# wbuild: step="bin/wfixture_ast_test"
