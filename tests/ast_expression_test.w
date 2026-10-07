import lib.testing
import lib.file
import lib.process


char* ast_test_path(char* suffix):
	string_builder* path = string_new()
	string_append(path, c"bin/ast_expression_")
	string_append_int(path, getpid())
	string_append(path, suffix)
	char* result = strclone(path.data)
	string_free(path)
	return result


process_result* ast_test_run(char** args, char* input):
	process_result* result = process_run(args[0], args, 0, input, 30000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


int ast_test_arg(char** args, int i, char* value):
	strv_set(args, i, value)
	return i + 1


process_result* ast_test_compile(char* compiler, char* arch, char* input, char* output, int enabled, int checking, int stats):
	char** args = strv_new(16)
	int i = 0
	i = ast_test_arg(args, i, compiler)
	if (checking):
		i = ast_test_arg(args, i, c"check")
		i = ast_test_arg(args, i, c"--json")
		i = ast_test_arg(args, i, c"--lint")
		i = ast_test_arg(args, i, c"--imports")
	if (strcmp(arch, c"x86") != 0): i = ast_test_arg(args, i, arch)
	i = ast_test_arg(args, i, c"--quiet")
	# The AST front end is the default (P1.4): the baseline (0) and the
	# grouped scalar mode (1) opt into the streaming front end.
	if (enabled < 2): i = ast_test_arg(args, i, c"--streaming")
	if (enabled == 1): i = ast_test_arg(args, i, c"--ast-expressions")
	if (enabled == 2): i = ast_test_arg(args, i, c"--ast-full-expressions")
	if (enabled == 3): i = ast_test_arg(args, i, c"--ast-required")
	if (enabled == 4):
		i = ast_test_arg(args, i, c"--ast-retain")
		i = ast_test_arg(args, i, c"--ast-required")
	if (stats): i = ast_test_arg(args, i, c"--stats")
	i = ast_test_arg(args, i, input)
	if (output != 0):
		i = ast_test_arg(args, i, c"-o")
		i = ast_test_arg(args, i, output)
	return ast_test_run(args, 0)


void ast_test_same_file(char* first, char* second):
	int fd = open(first, 0, 0)
	int gd = open(second, 0, 0)
	assert1(fd >= 0 && gd >= 0)
	int size = file_size(fd)
	assert_equal(size, file_size(gd))
	char* a = file_read_text(first)
	char* b = file_read_text(second)
	assert1(a != 0 && b != 0)
	assert_bytes_equal(a, b, size)
	free(a)
	free(b)
	close(fd)
	close(gd)


void ast_test_image_at(char* compiler, char* arch, char* source, int run):
	char* a = ast_test_path(c".legacy")
	char* b = ast_test_path(c".ast")
	process_result* old = ast_test_compile(compiler, arch, source, a, 0, 0, 0)
	for enabled in range(1, 3):
		# Every image in this helper is expected to compile. Reject any
		# full-mode expression fallback, including in driver-only fixtures.
		int mode = enabled
		if (mode == 2): mode = 3
		process_result* ast = ast_test_compile(compiler, arch, source, b, mode, 0, 0)
		assert_equal(0, old.status)
		assert_equal(0, ast.status)
		assert_strings_equal(old.stdout_text, ast.stdout_text)
		assert_strings_equal(old.stderr_text, ast.stderr_text)
		ast_test_same_file(a, b)
		process_result_free(ast)
		if (run):
			char** args = strv_new(1)
			strv_set(args, 0, b)
			ast = ast_test_run(args, 0)
			assert_equal(0, ast.status)
			process_result_free(ast)
	process_result_free(old)
	unlink(a)
	unlink(b)
	free(a)
	free(b)


void ast_test_image(char* compiler, char* arch, int run):
	ast_test_image_at(compiler, arch, c"tests/ast_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_typed_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_scalar_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_logic_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_remaining_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_mutation_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_text_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_print_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_buffer_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_comment_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_list_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_pointer_type_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_callback_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_default_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_allocation_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_multiline_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_metadata_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_record_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_map_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_parallel_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_increment_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_wide_call_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_template_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_generic_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_buffer_value_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_slice_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_container_literal_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_constructor_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_new_array_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_list_slice_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_list_method_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_void_call_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_composite_type_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_integer_intrinsic_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_map_method_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_generator_call_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_list_callback_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_map_default_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_inferred_generic_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_variadic_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_generic_type_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_method_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_operator_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_var_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_prelude_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_json_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_protobuf_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_utf8_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_large_literal_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_ndarray_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_buffer_flow_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_template_format_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_qualified_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_list_it_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_bare_callback_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_propagation_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_continuation_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_first_use_container_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_map_integration_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_collection_snapshot_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_control_header_fixture.w", run)
	if (strcmp(arch, c"x64") == 0): ast_test_image_at(compiler, arch, c"tests/ast_collection_snapshot_x64_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_statement_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_integration_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_scalar_map_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_array_allocation_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_migration_constructor_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_map_default_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_map_get_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_formatted_template_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_migration_generic_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_return_statement_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/unsigned_compare_test.w", run)
	if (strcmp(arch, c"x64") == 0): ast_test_image_at(compiler, arch, c"tests/x64_unsigned_compare_test.w", run)


void ast_test_retained_at(char* compiler, char* arch, int run):
	char* before = ast_test_path(c".legacy")
	char* after = ast_test_path(c".retained")
	process_result* legacy = ast_test_compile(compiler, arch, c"tests/ast_control_header_fixture.w", before, 0, 0, 0)
	process_result* retained = ast_test_compile(compiler, arch, c"tests/ast_control_header_fixture.w", after, 4, 0, 0)
	assert_equal(0, legacy.status)
	assert_equal(0, retained.status)
	assert_strings_equal(legacy.stdout_text, retained.stdout_text)
	assert_strings_equal(legacy.stderr_text, retained.stderr_text)
	ast_test_same_file(before, after)
	process_result_free(legacy)
	process_result_free(retained)
	if (run):
		char** args = strv_new(1)
		strv_set(args, 0, after)
		retained = ast_test_run(args, 0)
		assert_equal(0, retained.status)
		process_result_free(retained)
	unlink(before)
	unlink(after)
	free(before)
	free(after)


void test_ast_retained_image_parity():
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		ast_test_retained_at(compiler, c"x86", 1)
		ast_test_retained_at(compiler, c"x64", 1)
		ast_test_retained_at(compiler, c"arm64", 0)
		ast_test_retained_at(compiler, c"arm64_darwin", 0)
		ast_test_retained_at(compiler, c"win64", 0)
		ast_test_retained_at(compiler, c"wasm", 0)


void test_ast_expression_images_and_host_widths():
	ast_test_image(c"bin/wv2", c"x86", 1)
	ast_test_image(c"bin/wv2", c"x64", 1)
	ast_test_image(c"bin/wv2_64", c"x86", 1)
	ast_test_image(c"bin/wv2_64", c"x64", 1)
	ast_test_image(c"bin/wv2", c"arm64", 0)
	ast_test_image(c"bin/wv2", c"arm64_darwin", 0)
	ast_test_image(c"bin/wv2", c"win64", 0)
	ast_test_image(c"bin/wv2", c"wasm", 0)


void test_ast_c_variadic_images_and_host_widths():
	ast_test_image_at(c"bin/wv2", c"x86", c"tests/varargs_test.w", 1)
	ast_test_image_at(c"bin/wv2", c"x64", c"tests/varargs_test.w", 1)
	ast_test_image_at(c"bin/wv2_64", c"x86", c"tests/varargs_test.w", 1)
	ast_test_image_at(c"bin/wv2_64", c"x64", c"tests/varargs_test.w", 1)


void test_ast_atomic_images_and_host_widths():
	ast_test_image_at(c"bin/wv2", c"x86", c"tests/ast_atomic_expression_fixture.w", 1)
	ast_test_image_at(c"bin/wv2", c"x64", c"tests/ast_atomic_expression_fixture.w", 1)
	ast_test_image_at(c"bin/wv2_64", c"x86", c"tests/ast_atomic_expression_fixture.w", 1)
	ast_test_image_at(c"bin/wv2_64", c"x64", c"tests/ast_atomic_expression_fixture.w", 1)
	ast_test_image_at(c"bin/wv2", c"x86", c"tests/atomic_host_test.w", 1)
	ast_test_image_at(c"bin/wv2", c"x64", c"tests/atomic_host_test.w", 1)


void ast_test_diagnostics_mode(char* source, int checking):
	char* path = ast_test_path(c".w")
	char* output = 0
	if (checking == 0): output = ast_test_path(c".diagnostic")
	assert1(file_write_text(path, source))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* old = ast_test_compile(compiler, c"x64", path, output, 0, checking, 0)
		for enabled in range(1, 3):
			process_result* ast = ast_test_compile(compiler, c"x64", path, output, enabled, checking, 0)
			assert_equal(old.status, ast.status)
			assert_strings_equal(old.stdout_text, ast.stdout_text)
			assert_strings_equal(old.stderr_text, ast.stderr_text)
			process_result_free(ast)
		process_result_free(old)
	unlink(path)
	free(path)
	if (output != 0):
		unlink(output)
		free(output)


void ast_test_diagnostics(char* source):
	ast_test_diagnostics_mode(source, 1)


void ast_test_store_diagnostics(char* source):
	ast_test_diagnostics_mode(source, 1)
	# Exercise both lint diagnostics and ordinary compilation.
	ast_test_diagnostics_mode(source, 0)


void test_ast_expression_diagnostics_and_fallback():
	ast_test_diagnostics(c"int main():\n\tint x = 1\n\t\tin 2\n\treturn x\n")
	ast_test_diagnostics(c"int main(): return (0xffffffff + 0x80000000)\n")
	ast_test_diagnostics(c"int main(): return (0x100000000 + 2)\n")
	ast_test_diagnostics(c"int main(): return (4294967296 + 2)\n")
	ast_test_diagnostics(c"int main(): return (0b100000000000000000000000000000000 + 2)\n")
	ast_test_diagnostics(c"int main(): return (0xffffffff + )\n")
	ast_test_diagnostics(c"int main(): return (0xffffffff + \"unterminated\n")
	ast_test_diagnostics(c"int main(): return (0xffffffff + 2)")
	ast_test_diagnostics(c"int main(): return (0xffffffff + 1e+2)\n")
	ast_test_diagnostics(c"int main(): return (1 ++ 2)\n")
	ast_test_diagnostics(c"int main(): return (1 + /* unclosed\n")
	ast_test_diagnostics(c"int main():\n    return (1 + 2)\n")
	ast_test_diagnostics(c"int main():\n\tint x = 1\n\tif (x = (1 + 2)): return 1\n\tx = x\n\treturn x\n")
	ast_test_diagnostics(c"int main(): return (2 + 3) = 4\n")
	# Limits must fall back, and deep expressions must still reach the
	# existing nesting diagnostic instead of overflowing the AST arena.
	string_builder* source = string_from(c"int main(): return (")
	for i in range(2200): string_append(source, c"1+")
	string_append(source, c"1)\n")
	ast_test_diagnostics(source.data)
	string_free(source)
	source = string_from(c"int main(): return ")
	for i in range(1005): string_append(source, c"(")
	string_append(source, c"1")
	for i in range(1005): string_append(source, c")")
	string_append(source, c"\n")
	ast_test_diagnostics(source.data)
	string_free(source)


void test_ast_typed_expression_diagnostics():
	ast_test_diagnostics(c"int main():\n\tconst int fixed = 7\n\tif 1: (fixed) = 8\n\treturn 0\n")
	ast_test_diagnostics(c"int main():\n\tint kept = 7\n\tint unused = 8\n\treturn (kept + 2)\n")
	ast_test_diagnostics(c"int main():\n\tint x = 7\n\tif 1:\n\t\tint x = 8\n\t\tif (x): pass\n\treturn (x + 2)\n")
	ast_test_diagnostics(c"int main():\n\tint x = 7\n\treturn (x + missing)\n")
	ast_test_diagnostics(c"int main():\n\tint x = 7\n\treturn (x + 0xffffffff + )\n")
	ast_test_diagnostics(c"int main():\n\tbool yes = true\n\tif (yes) & (!false): return 1\n\treturn 0\n")
	ast_test_diagnostics(c"int main():\n\tfloat x = 1.5\n\treturn (~x)\n")
	ast_test_diagnostics(c"int main():\n\tvar x = 7\n\treturn (~x)\n")
	ast_test_diagnostics(c"int main():\n\tint cast = 7\n\treturn (cast)\n")
	ast_test_diagnostics(c"import tests.ast_typed_expression_fixture as typed\nint other(): return (ast_named_global + 0xffffffff)\n")


void test_ast_scalar_expression_diagnostics():
	ast_test_diagnostics(c"float main(): return (1e+ + 0xffffffff)\n")
	ast_test_diagnostics(c"float main(): return (0xffffffff + 1.2bad)\n")
	ast_test_diagnostics(c"float main(): return (1.5 % 2)\n")
	ast_test_diagnostics(c"float main(): return (~1.5)\n")
	ast_test_diagnostics(c"int f(int* p): return 0\nint main(): return (f(7 + 1) + 0xffffffff)\n")
	ast_test_diagnostics(c"int f(int* p): return 0\nint main():\n\tint n = 1\n\treturn (f(n) + 0xffffffff)\n")
	ast_test_diagnostics(c"int f(int a): return a\nint main(): return (f(0xffffffff, 2))\n")
	ast_test_diagnostics(c"int f(int a): return a\nint main(): return (f())\n")
	ast_test_diagnostics(c"int f(int a): return a\nint main(): return (f(1,))\n")
	ast_test_diagnostics(c"int f(int a): return a\nint main(): return (f(missing))\n")
	ast_test_diagnostics(c"import tests.ast_scalar_expression_fixture as scalar\nint other(): return (ast_zero() + 0xffffffff)\n")


void test_ast_logic_expression_diagnostics():
	ast_test_diagnostics(c"int main(): return (false && missing)\n")
	ast_test_diagnostics(c"int f(int a): return a\nint main(): return (true || f())\n")
	ast_test_diagnostics(c"int main(): return (false && 4294967296)\n")
	ast_test_diagnostics(c"int main(): return (true || 1e+)\n")
	ast_test_diagnostics(c"int main():\n\tint n = 1\n\treturn (n.missing + 0xffffffff)\n")
	ast_test_diagnostics(c"struct R:\n\tint field\nint main():\n\tR r\n\treturn (r.missing + 0xffffffff)\n")
	ast_test_diagnostics(c"int main():\n\tint* p = 0\n\treturn (p[missing] > 2)\n")
	ast_test_diagnostics(c"int main():\n\tint* p = 0\n\treturn (p[1 + 0xffffffff)\n")
	ast_test_diagnostics(c"int main():\n\tint n = 1\n\tif (n < 2) & (n != 3): return 1\n\treturn 0\n")
	ast_test_diagnostics(c"int main():\n\tconst int n = 1\n\tif 1: (n) = 2\n\treturn 0\n")
	ast_test_diagnostics(c"int main():\n\tint n = 1\n\treturn (n = 2)\n")


void test_ast_full_expression_boundaries():
	ast_test_diagnostics(c"int main():\n\tint a = 1\n\tint b = 2\n\ta, b = b, a\n\treturn a + b\n")
	ast_test_diagnostics(c"int main():\n\tint x = 6 * 7\n    return x\n")
	ast_test_diagnostics(c"int main():\n\treturn 6 * 7 # no final newline")
	ast_test_diagnostics(c"int main(): return 6 * 7")
	ast_test_diagnostics(c"int main():\n\tint x = 0xffffffff\n\treturn 4294967296\n")
	ast_test_diagnostics(c"int main():\n\tint n = 1\n\tn++\n\treturn n\n")


void test_ast_full_expression_coverage_gate():
	char* path = ast_test_path(c"_gate.w")
	assert1(file_write_text(path, c"int main(): return 6 * 7\n"))
	char** args = strv_new(6)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--quiet")
	strv_set(args, 3, c"--ast-audit")
	strv_set(args, 4, c"--stats")
	strv_set(args, 5, path)
	process_result* audit = ast_test_run(args, 0)
	assert_equal(0, audit.status)
	assert_substring(audit.stderr_text, c"\"ast_fallback\": true", 0)
	assert_contains(audit.stderr_text, c"AST expression roots: ")
	assert_contains(audit.stderr_text, c"Streaming expression roots: 0\n")
	# The final newline is a supported boundary even at physical EOF.
	assert_substring(audit.stderr_text, path, 0)
	process_result_free(audit)
	args = strv_new(5)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--quiet")
	strv_set(args, 3, c"--ast-required")
	strv_set(args, 4, path)
	process_result* required = ast_test_run(args, 0)
	assert_equal(0, required.status)
	process_result_free(required)
	# An expression exceeding the bounded arena still proves required
	# mode cannot silently use the streaming fallback.
	string_builder* large = string_from(c"int main(): return ")
	for i in range(2200): string_append(large, c"1+")
	string_append(large, c"1\n")
	assert1(file_write_text(path, large.data))
	string_free(large)
	args = strv_new(5)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--quiet")
	strv_set(args, 3, c"--ast-required")
	strv_set(args, 4, path)
	required = ast_test_run(args, 0)
	assert_equal(1, required.status)
	assert_contains(required.stderr_text, c"AST-required compilation encountered an unsupported expression")
	assert_contains(required.stderr_text, path)
	process_result_free(required)
	unlink(path)
	free(path)


void test_ast_mutation_expression_diagnostics():
	ast_test_diagnostics(c"int main():\n\tint x = 1\n\tx = x\n\tif (x = 2): return x\n\treturn x\n")
	ast_test_diagnostics(c"int main():\n\tconst int x = 1\n\treturn (x += 2)\n")
	ast_test_diagnostics(c"int main(): return (1 = 2)\n")
	ast_test_diagnostics(c"int main():\n\tfloat32 x = 1.5\n\treturn (x %= 2)\n")
	ast_test_diagnostics(c"int main():\n\tint* p = 0\n\tint x = 1\n\treturn (p = x)\n")


void test_ast_mutation_expression_path_is_exercised():
	char* path = ast_test_path(c"_mutation.w")
	char* output = ast_test_path(c"_mutation")
	assert1(file_write_text(path, c"int main():\n\tint x = 1\n\treturn (x += 2)\n"))
	process_result* ast = ast_test_compile(c"bin/wv2", c"x86", path, output, 1, 0, 1)
	assert_equal(0, ast.status)
	assert_contains(ast.stderr_text, c"AST expressions: 1\n")
	process_result_free(ast)
	unlink(output)
	unlink(path)
	free(output)
	free(path)


void test_ast_text_expression_diagnostics():
	ast_test_diagnostics(c"int main(): return ('ab')\n")
	ast_test_diagnostics(c"int main(): return ('\\q')\n")
	ast_test_diagnostics(c"int main(): return ('\\uD800')\n")
	ast_test_diagnostics(c"import lib.lib\nint main(): return (strlen(c\"\\xGG\"))\n")
	ast_test_diagnostics(c"int main(): return (s\"\\xff\" == s\"x\")\n")
	ast_test_diagnostics(c"int main(): return (s\"\\uD800\" == s\"x\")\n")
	ast_test_diagnostics(c"int main(): return (f\"bad}\" == s\"x\")\n")
	ast_test_diagnostics(c"int main():\n\tstring text = s\"x\"\n\ttext += 1\n\treturn 0\n")
	ast_test_diagnostics(c"int main(): return ('x' + 0xffffffff)\n")
	ast_test_diagnostics(c"int main():\n\tchar* text = c\"decoded\\n\"\n    return 0\n")


void test_ast_text_expression_path_is_exercised():
	char* path = ast_test_path(c"_text.w")
	assert1(file_write_text(path, c"int f(char* a, char* b): return a == b\nint main(): return (f(c\"hello\", c\"hello\") + 'a')\n"))
	process_result* ast = ast_test_compile(c"bin/wv2", c"x86", path, 0, 1, 1, 1)
	assert_equal(0, ast.status)
	assert_contains(ast.stderr_text, c"AST expressions: 1\n")
	process_result_free(ast)
	unlink(path)
	free(path)


void test_ast_remaining_expression_diagnostics():
	ast_test_diagnostics(c"int main(): return (cast(int, 0xffffffff) + 0xffffffff)\n")
	ast_test_diagnostics(c"int main(): return (cast(int, 4294967296))\n")
	ast_test_diagnostics(c"int main(): return (cast(missing, 1))\n")
	ast_test_diagnostics(c"int main():\n\tint* p = 0\n\treturn (cast(int16, p))\n")
	ast_test_diagnostics(c"int main():\n\tint* p = 0\n\tint x = 1\n\treturn (true ? p : x)\n")
	ast_test_diagnostics(c"int main(): return (false ? 0xffffffff : missing)\n")
	ast_test_diagnostics(c"int main(): return (true ? 1 : 4294967296)\n")
	ast_test_diagnostics(c"int main():\n\tbool a = true\n\tbool b = false\n\tif (a & b | a): return 1\n\treturn 0\n")


void test_ast_remaining_expression_path_is_exercised():
	char* path = ast_test_path(c"_remaining.w")
	assert1(file_write_text(path, c"int f(int x): return (x > 0 ? cast(int, 0xffffffff) & x << 2 : x ^ 7)\nint main(): return 0\n"))
	process_result* ast = ast_test_compile(c"bin/wv2", c"x64", path, 0, 1, 1, 1)
	assert_equal(0, ast.status)
	assert_contains(ast.stderr_text, c"AST expressions: 1\n")
	process_result_free(ast)
	unlink(path)
	free(path)


void test_ast_typed_expression_tls_and_fallback_images():
	char* path = ast_test_path(c"_tls.w")
	assert1(file_write_text(path, c"thread_local int tls_value\nint main():\n\ttls_value = 17\n\treturn (tls_value + 25) != 42\n"))
	ast_test_image_at(c"bin/wv2", c"x86", path, 1)
	ast_test_image_at(c"bin/wv2_64", c"x64", path, 1)
	assert1(file_write_text(path, c"int main():\n\tint64 wide = 15\n\tuint64 unsigned_wide = 17\n\treturn (wide + unsigned_wide * 2) != 49\n"))
	ast_test_image_at(c"bin/wv2", c"x64", path, 1)
	ast_test_image_at(c"bin/wv2_64", c"x64", path, 1)
	ast_test_image_at(c"bin/wv2", c"x86", c"tests/operator_overload_test.w", 1)
	ast_test_image_at(c"bin/wv2_64", c"x64", c"tests/operator_overload_test.w", 1)
	unlink(path)
	free(path)


void test_ast_scalar_expression_float_widths():
	char* path = ast_test_path(c"_float.w")
	assert1(file_write_text(path, c"float32 half_sum(float16 a, float16 b): return (a + b)\nint main():\n\tfloat16 half = 1.5\n\tif ((half_sum(half, 2.5) * 2) != 8.0): return 1\n\treturn 0\n"))
	ast_test_image_at(c"bin/wv2", c"x86", path, 1)
	ast_test_image_at(c"bin/wv2_64", c"x64", path, 1)
	assert1(file_write_text(path, c"float64 wide(float64 a, float32 b): return (a + b)\nint main():\n\tfloat64 a = (1.0000000000000002)\n\tif ((wide(a, 2.5) * 2) != 7.0): return 1\n\tfloat64 z = (-0.0)\n\tint* bits = &z\n\tif *bits != (1 << 63): return 2\n\treturn 0\n"))
	ast_test_image_at(c"bin/wv2", c"x64", path, 1)
	ast_test_image_at(c"bin/wv2_64", c"x64", path, 1)
	unlink(path)
	free(path)


void test_ast_expression_path_is_exercised():
	char* path = ast_test_path(c".w")
	assert1(file_write_text(path, c"int main(): return (6 * 7)\n"))
	process_result* ast = ast_test_compile(c"bin/wv2", c"x86", path, 0, 1, 1, 1)
	assert_equal(0, ast.status)
	assert_contains(ast.stderr_text, c"AST expressions: 1\n")
	process_result_free(ast)
	assert1(file_write_text(path, c"int f(int x, uint8 y): return (x + y * 2)\nint main(): return 0\n"))
	ast = ast_test_compile(c"bin/wv2", c"x86", path, 0, 1, 1, 1)
	assert_equal(0, ast.status)
	assert_contains(ast.stderr_text, c"AST expressions: 1\n")
	process_result_free(ast)
	assert1(file_write_text(path, c"float main(): return (1.5 + 2.5)\n"))
	ast = ast_test_compile(c"bin/wv2", c"x86", path, 0, 1, 1, 1)
	assert_equal(0, ast.status)
	assert_contains(ast.stderr_text, c"AST expressions: 1\n")
	process_result_free(ast)
	assert1(file_write_text(path, c"int f(int x): return x\nint g(int16* p): return (f(2) + f(3))\nint16* h(int16* p): return (p + 2)\nint main(): return 0\n"))
	ast = ast_test_compile(c"bin/wv2", c"x86", path, 0, 1, 1, 1)
	assert_equal(0, ast.status)
	assert_contains(ast.stderr_text, c"AST expressions: 2\n")
	process_result_free(ast)
	# Start the group across the 8 KiB tokenizer window boundary. The
	# preflight must decline without reading/repositioning the stream.
	string_builder* source = string_from(c"#")
	char* prefix = c"\nint main(): return "
	while (source.length < 8190 - strlen(prefix)): string_append_char(source, ' ')
	string_append(source, prefix)
	string_append(source, c"(6 * 7)\n")
	assert1(file_write_text(path, source.data))
	ast = ast_test_compile(c"bin/wv2", c"x86", path, 0, 1, 1, 1)
	assert_equal(0, ast.status)
	assert_contains(ast.stderr_text, c"AST expressions: 0\n")
	process_result_free(ast)
	ast_test_diagnostics(source.data)
	string_free(source)
	unlink(path)
	free(path)


void test_ast_logic_expression_path_is_exercised():
	char* path = ast_test_path(c"_logic.w")
	assert1(file_write_text(path, c"struct R:\n\tint x\nint f(int a): return a\nbool g(int a, int b, int* p, R* r): return (a < b && f(a) != b || p[0] == r.x)\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 1\n")
		process_result_free(ast)
	unlink(path)
	free(path)


process_result* ast_test_query(char* command, int enabled, char* source):
	char** args = strv_new(7)
	int i = 0
	i = ast_test_arg(args, i, c"bin/wv2")
	i = ast_test_arg(args, i, command)
	if (strcmp(command, c"defhash") != 0): i = ast_test_arg(args, i, c"--json")
	i = ast_test_arg(args, i, c"--quiet")
	if (enabled < 2): i = ast_test_arg(args, i, c"--streaming")
	if (enabled == 1): i = ast_test_arg(args, i, c"--ast-expressions")
	if (enabled == 2): i = ast_test_arg(args, i, c"--ast-full-expressions")
	strv_set(args, i, source)
	return ast_test_run(args, 0)


void test_ast_composite_types_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_composite_type_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\treturn (new list[void]).length\n")
	ast_test_store_diagnostics(c"struct R:\n\tint[2] values\nint main():\n\treturn (new list[R]).length\n")
	ast_test_store_diagnostics(c"struct R:\n\tint[2] values\nint main():\n\treturn (new map[int, R]).length\n")
	ast_test_store_diagnostics(c"int main():\n\treturn (list[uint16]{1} + missing)\n")


void test_ast_integer_intrinsics_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_integer_intrinsic_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main(): return mul_hi(c\"bad\", 1)\n")
	ast_test_store_diagnostics(c"int main(): return mul_wide(1, 2, c\"bad\")\n")
	ast_test_store_diagnostics(c"int main(): return add_carry(1, 2)\n")
	ast_test_store_diagnostics(c"int main(): return rotl(1, 2, 3)\n")
	ast_test_store_diagnostics(c"int main(): return clz(c\"bad\")\n")


void test_ast_map_methods_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_map_method_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main():\n\tmap[int, R] m = new map[int, R]\n\tm.add(1)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] m = new map[int, int]\n\tm.add(1, c\"bad\")\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] m = new map[int, int]\n\treturn m.keys(1).length\n")


void test_ast_generator_calls_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_generator_call_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"import lib.generator\ngenerator int g(int n): yield n\nint main():\n\tgenerator* value = g()\n\tgen_free(value)\n\treturn 0\n")
	ast_test_store_diagnostics(c"import lib.generator\ngenerator int g(int n): yield n\nstruct R:\n\tint x\nint main():\n\tR r = R(1)\n\tgenerator* value = g(r)\n\tgen_free(value)\n\treturn 0\n")


void test_ast_list_callbacks_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_list_callback_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1}\n\tvalues.map(3)\n\treturn 0\n")
	ast_test_store_diagnostics(c"void f(int value): return\nint main():\n\tlist[int] values = list[int]{1}\n\tvalues.map(f)\n\treturn 0\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint f(int a, int b): return a + b\nint main():\n\tlist[int] values = list[int]{1}\n\tvalues.reduce(f, R(2))\n\treturn 0\n")


void test_ast_map_defaults_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_map_default_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] values = new map[int, int]()\n\treturn values.length\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int*] values = new map[int, int*](0)\n\treturn values.length\n")
	ast_test_store_diagnostics(c"char* factory(): return c\"bad\"\nint main():\n\tmap[int, int] values = new map[int, int](factory)\n\treturn values.length\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main():\n\tmap[int, R] values = new map[int, R](R(1))\n\treturn values.length\n")


void test_ast_inferred_generic_calls_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_inferred_generic_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"T f[T](T a, T b): return a\nint main(): return f(1, 1.5)\n")
	ast_test_store_diagnostics(c"T* f[T](T* value): return value\nint main(): return f(1)\n")
	ast_test_store_diagnostics(c"int f[T](int value): return value\nint main(): return f(1)\n")
	ast_test_store_diagnostics(c"T f[T](T value): return value\nstruct R:\n\tint x\nint main():\n\tR r = R(1)\n\tf(r)\n\treturn 0\n")
	ast_test_store_diagnostics(c"T f[T](T value): return value\nint g(): return 1\nint main(): return f(g)\n")

	ast_test_store_diagnostics(c"T f[T](T value, list[T] items): return value\nint main(): return f(1, list[char]{'a'})\n")
	ast_test_store_diagnostics(c"int f[T](list[T] items): return items.length\nint main(): return f(list[int]{1})\n")
	ast_test_store_diagnostics(c"T f[T](T value, map[T, list[void]] items): return value\nint main(): return f(1, 0)\n")


void test_ast_variadic_calls_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_variadic_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int f(int fixed, int... values): return fixed\nint main(): return f()\n")
	ast_test_store_diagnostics(c"int f(int... values): return values.length\nint main(): return f(1, c\"bad\")\n")


void test_ast_c_variadic_calls_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/varargs_test.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"c_lib \"libc.so.6\"\nextern int printf(char* format, ...)\nint main(): return printf()\n")
	ast_test_store_diagnostics(c"c_lib \"libc.so.6\"\nextern int printf(char* format, ...)\nstruct R:\n\tint x\nint main(): return printf(c\"%d\", R(1))\n")


void test_ast_atomic_calls_are_required():
	for fixture in range(2):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_atomic_expression_fixture.w"
			if (fixture): source = c"tests/atomic_host_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tchar value = 1\n\tchar* p = &value\n\treturn atomic_add(p, 1)\n")
	ast_test_store_diagnostics(c"int main():\n\tint value = 1\n\treturn atomic_cas(&value, 1)\n")
	ast_test_store_diagnostics(c"int main():\n\tint value = 1\n\treturn atomic_min(&value, 1)\n")


void test_ast_generic_types_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_generic_type_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"struct Box[T]:\n\tT value\nint main(): return cast(Box[int, int]*, 0)\n")
	ast_test_store_diagnostics(c"struct Box[T]:\n\tT value\nint main(): return sizeof(Box[Missing])\n")


void test_ast_method_calls_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_method_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main():\n\tR value\n\treturn value.missing()\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint take(R value): return value.x\nint main():\n\tR value\n\treturn value.take()\n")
	ast_test_store_diagnostics(c"int take(int value, int other): return value + other\nint main():\n\tint value = 1\n\treturn value.take()\n")


void test_ast_operator_calls_are_required():
	for fixture in range(2):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_operator_expression_fixture.w"
			if (fixture): source = c"tests/operator_overload_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main():\n\tR a = R(1)\n\tR b = R(2)\n\treturn a + b\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nR operator+(R a, R b): return a\nint main():\n\tR a = R(1)\n\treturn a + 2\n")


void test_ast_var_expressions_are_required():
	for fixture in range(2):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_var_expression_fixture.w"
			if (fixture): source = c"tests/dynamic_var_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tvar a = 1\n\treturn a % 2\n")
	ast_test_store_diagnostics(c"int main():\n\tvar a = 1\n\treturn a << 1\n")
	ast_test_store_diagnostics(c"int main():\n\tvar a = 1\n\treturn a & 1\n")
	ast_test_store_diagnostics(c"int main():\n\tvar a = 1\n\treturn ~a\n")
	ast_test_store_diagnostics(c"int main():\n\tvar a = 1\n\treturn cast(float, a)\n")
	ast_test_store_diagnostics(c"int main():\n\tvar a = 1\n\treturn cast(var, 1.5)\n")



void test_ast_json_expressions_are_required():
	for fixture in range(2):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_json_expression_fixture.w"
			if (fixture): source = c"tests/json_codec_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"struct R:\n\tint n\nint main():\n\tR value\n\tto_json(value)\n\treturn 0\n")
	ast_test_store_diagnostics(c"import structures.json\nstruct R:\n\tset[int] values\nint main():\n\tR value\n\tto_json(value)\n\treturn 0\n")
	ast_test_store_diagnostics(c"import structures.json\nstruct R:\n\tint n\nint main():\n\tfrom_json(R, c\"bad\")\n\treturn 0\n")
	ast_test_store_diagnostics(c"import structures.json\nstruct R:\n\tmap[int, int] values\nint main():\n\tfrom_json(R, 0)\n\treturn 0\n")



void test_ast_protobuf_expressions_are_required():
	for fixture in range(2):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_protobuf_expression_fixture.w"
			if (fixture): source = c"tests/protobuf_message_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tto_proto(1)\n\treturn 0\n")
	ast_test_store_diagnostics(c"import libs.extras.protobuf.message\nmessage R:\n\tint32 n = 1\nint main():\n\tfrom_proto(R, c\"bad\")\n\treturn 0\n")
	ast_test_store_diagnostics(c"import libs.extras.protobuf.message\nmessage Later\nmessage R:\n\tLater n = 1\nint main():\n\tproto_descriptor(R)\n\treturn 0\n")
	ast_test_store_diagnostics(c"import libs.extras.protobuf.message\nstruct R:\n\tint n\nint main():\n\tR value\n\tto_proto(value)\n\treturn 0\n")



void test_ast_ndarray_expressions_are_required():
	for fixture in range(2):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_ndarray_expression_fixture.w"
			if (fixture): source = c"tests/ndarray_index_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"import lib.ndarray\nint main():\n\tndi value = ndi_new2(2, 2)\n\tvalue[0, 0]++\n\treturn 0\n")
	ast_test_store_diagnostics(c"import lib.ndarray\nint main():\n\tndi value = ndi_new2(2, 2)\n\t(value[0, 0]) = 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"import lib.ndarray\nint main():\n\tndi value = ndi_new2(2, 2)\n\tvalue[0, 0, 0, 0, 0]\n\treturn 0\n")
	ast_test_store_diagnostics(c"import lib.ndarray\nint main():\n\tndi value = ndi_new2(2, 2)\n\tvalue[c\"bad\", 0]\n\treturn 0\n")
	ast_test_store_diagnostics(c"import lib.ndarray\nint main():\n\tndi value = ndi_new2(2, 2)\n\tvalue[0, 0] = c\"bad\"\n\treturn 0\n")



void test_ast_buffer_flow_expressions_are_required():
	for fixture in range(3):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_buffer_flow_expression_fixture.w"
			if (fixture == 1): source = c"tests/array_decay_test.w"
			if (fixture == 2): source = c"tests/matrix_linalg_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tint[2] a\n\tchar* p = true ? a : c\"bad\"\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tint[2] a\n\tint[2] b\n\t(true ? a : b) = a\n\treturn 0\n")



void test_ast_utf8_expressions_are_required():
	for fixture in range(2):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_utf8_expression_fixture.w"
			if (fixture): source = c"tests/utf8_identifier_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\treturn (1 + café_missing)\n")
	ast_test_store_diagnostics(c"int main():\n\treturn (1 + caf́)\n")
	ast_test_store_diagnostics(c"int main():\n\treturn (1 + caf‮)\n")
	ast_test_store_diagnostics(c"int main():\n\treturn (1 + caf​)\n")
	ast_test_store_diagnostics(c"int main():\n\treturn (1 + caf\xc3x)\n")



void test_ast_large_literal_expressions_are_required():
	for fixture in range(2):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_large_literal_expression_fixture.w"
			if (fixture): source = c"graphics/ui/font_data.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)


void test_ast_prelude_input_images_and_runtime():
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		for target in range(2):
			char* arch = c"x86"
			if (target): arch = c"x64"
			ast_test_image_at(compiler, arch, c"tests/ast_prelude_input_fixture.w", 0)
			char* output = ast_test_path(c".prelude")
			process_result* compiled = ast_test_compile(compiler, arch, c"tests/ast_prelude_input_fixture.w", output, 2, 0, 0)
			assert_equal(0, compiled.status)
			process_result_free(compiled)
			for variant in range(3):
				char* mode = c"i"
				char* input = c"header\n1 -2 3\n"
				char* expected = c"[1, -2, 3]\n"
				if (variant == 1):
					mode = c"l"
					input = c"one two\nthree four\n"
					expected = c"[one two, three four]\n"
				if (variant == 2):
					mode = c"w"
					input = c"one two\nthree four\n"
					expected = c"[one, two, three, four]\n"
				char** args = strv_new(2)
				strv_set(args, 0, output)
				strv_set(args, 1, mode)
				process_result* result = ast_test_run(args, input)
				assert_equal(0, result.status)
				assert_strings_equal(expected, result.stdout_text)
				process_result_free(result)
			unlink(output)
			free(output)


void test_ast_prelude_expressions_are_required():
	for fixture in range(3):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_prelude_expression_fixture.w"
			if (fixture == 1): source = c"tests/ast_prelude_input_fixture.w"
			if (fixture == 2): source = c"tests/prelude_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tmax(1.5, 2)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tlen(1)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tany(list[float]{1.5})\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tsplit(1)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tjoin(list[int]{1}, c\",\")\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tenum_name(2)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tinput(1)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tprint(list[float]{1.5})\n\treturn 0\n")

void test_ast_bit_field_expressions_are_required():
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		for fixture in range(2):
			char** args = strv_new(5 + fixture)
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/c_import_bitfield_fixture.w"
			char* arch = c"x86"
			if (fixture):
				source = c"tests/x64_c_import_bitfield_test.w"
				arch = c"x64"
			if (fixture): strv_set(args, 4, arch)
			strv_set(args, 4 + fixture, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
			ast_test_image_at(compiler, arch, source, fixture)
	ast_test_store_diagnostics(c"c_import \"libc.so.6\" c\"tests/c_import_bitfield_fixture.h\"\nint main():\n\tci_bf_wide* value = 0\n\treturn value.a\n")


void test_ast_void_calls_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_void_call_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)


void test_ast_list_methods_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_list_method_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tlist[float32] values = list[float32]{1.5}\n\tvalues.sort()\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[char*] values = list[char*]{c\"a\"}\n\treturn values.sum()\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1}\n\treturn values.count(c\"bad\")\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1}\n\tint it = 3\n\treturn values.sum()\n")


void test_ast_list_slices_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_list_slice_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1, 2}\n\treturn (values[1 + :2].length)\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1, 2}\n\tvalues[:].length = 1\n\treturn 0\n")


void test_ast_new_arrays_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_new_array_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tvoid[] values = new void[2]\n\treturn values.length\n")
	ast_test_store_diagnostics(c"int main():\n\tint[] values = new int[missing]\n\treturn values.length\n")
	ast_test_store_diagnostics(c"int main():\n\tint[] values = new int[4294967296]\n\treturn values.length\n")


void test_ast_constructors_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_constructor_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"struct R:\n\tint a\n\tint b\nint main():\n\tR value = R(1)\n\treturn value.a\n")
	ast_test_store_diagnostics(c"struct R:\n\tint a\nint main():\n\tR* value = new R(1, 2)\n\treturn value.a\n")
	ast_test_store_diagnostics(c"struct R:\n\tint a\nint main():\n\tR value = R(missing: 1)\n\treturn value.a\n")
	ast_test_store_diagnostics(c"struct R:\n\tint a\n\tint b\nint main():\n\tR value = R(a: 1, 2)\n\treturn value.a\n")
	ast_test_store_diagnostics(c"struct R:\n\tint[2] a\nint main():\n\tint[2] data\n\tR value = R(data)\n\treturn value.a[0]\n")
	ast_test_store_diagnostics(c"struct R:\n\tint a\nint main():\n\tR value = R(c\"bad\")\n\treturn value.a\n")


void test_ast_container_literals_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_container_literal_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{c\"bad\"}\n\treturn values.length\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] values = map[int, int]{1: missing}\n\treturn values.length\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] values = map[int, int]{1, 2}\n\treturn values.length\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1 + , 2}\n\treturn values.length\n")


void test_ast_slices_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_slice_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tint[3] values\n\treturn (cast(char, values))\n")
	ast_test_store_diagnostics(c"int main():\n\tint[3] values\n\treturn (cast(char*, values)[0])\n")
	ast_test_store_diagnostics(c"int main():\n\tint[3] values\n\treturn (values[0:missing].length)\n")
	ast_test_store_diagnostics(c"int main():\n\tint[3] values\n\treturn (values[1 + :2].length)\n")
	ast_test_store_diagnostics(c"int main():\n\tint[3] values\n\tvalues[:].length = 1\n\treturn 0\n")


void test_ast_buffer_values_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_buffer_value_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int take(int* p): return p[0]\nint main():\n\tchar[3] data\n\treturn (take(data))\n")
	ast_test_store_diagnostics(c"int take(int* p): return p[0]\nint main():\n\tint[3] data\n\treturn (take(data) + missing)\n")


void test_ast_generic_calls_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_generic_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"T id[T](T value): return value\nint main(): return (id[int](1, 2))\n")
	ast_test_store_diagnostics(c"T id[T](T value): return value\nint main(): return (id[int]())\n")
	ast_test_store_diagnostics(c"T id[T](T value): return value\nint main(): return (id[int, char](1))\n")
	ast_test_store_diagnostics(c"T id[T](T value): return value\nint main(): return (id[int](c\"text\"))\n")
	ast_test_store_diagnostics(c"T id[T](T value): return value\nint main(): return (id[int](4294967296))\n")
	# Failed outer probes must roll back queued signatures and pointers.
	ast_test_store_diagnostics(c"T* id[T](int value): return cast(T*, value)\nstruct Fresh:\n\tint value\nint main(): return (id[Fresh](0) + missing)\n")


void test_ast_lint_events_are_required():
	for fixture in range(2):
		char* source = c"tests/lint_warn_fixture.w"
		if (fixture): source = c"tests/lint_clean_fixture.w"
		for host in range(2):
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			for json in range(2):
				process_result* old = 0
				for enabled in range(2):
					char** args = strv_new(9)
					int i = 0
					i = ast_test_arg(args, i, compiler)
					i = ast_test_arg(args, i, c"check")
					i = ast_test_arg(args, i, c"--quiet")
					i = ast_test_arg(args, i, c"--lint")
					if (json): i = ast_test_arg(args, i, c"--json")
					if (enabled == 0): i = ast_test_arg(args, i, c"--streaming")
					if (enabled): i = ast_test_arg(args, i, c"--ast-required")
					if (host): i = ast_test_arg(args, i, c"x64")
					i = ast_test_arg(args, i, source)
					process_result* result = ast_test_run(args, 0)
					if (enabled == 0): old = result
					else:
						assert_equal(0, result.status)
						assert_equal(old.status, result.status)
						assert_strings_equal(old.stdout_text, result.stdout_text)
						assert_strings_equal(old.stderr_text, result.stderr_text)
						process_result_free(result)
				process_result_free(old)
	ast_test_diagnostics(c"int main():\n\tint a = 1\n\ta = a\n\ta = (a)\n\tif (a = a): return 1\n\tif ((a = a)): return 2\n\tif a = a: return 3\n\treturn a\n")
	ast_test_diagnostics(c"int main():\n\tint a = 1\n\tif a = 0xffffffff: return 1\n\tif a = missing: return 2\n\treturn a\n")
	ast_test_diagnostics(c"int main():\n\tint a = 1\n\tif (a = (a = 2)): return 1\n\treturn a\n")

	ast_test_diagnostics(c"int main():\n\tint a = 0\n\tmap[int,int] m = new map[int,int]\n\tif (m[0] = a = 1): return 1\n\treturn a\n")
	ast_test_diagnostics(c"int main():\n\tint a = 0\n\tmap[int,int] m = new map[int,int]\n\tif m[0] += a = 1: return 1\n\treturn a\n")

	ast_test_diagnostics(c"import lib.ndarray\nint main():\n\tint a = 0\n\tndi m = ndi_new2(1, 1)\n\tif (m[0, 0] = a = 1): return 1\n\treturn a\n")


void test_ast_bool_warning_events_are_required():
	for fixture in range(3):
		char* source = c"tests/bool_bitwise_warning_fixture.w"
		if (fixture == 1): source = c"tests/bool_bitwise_chain_fixture.w"
		if (fixture == 2): source = c"tests/bool_ops_warn_fixture.w"
		for host in range(2):
			char* compiler = c"bin/wv2"
			char* arch = c"x86"
			if (host):
				compiler = c"bin/wv2_64"
				arch = c"x64"
			ast_test_image_at(compiler, arch, source, 0)
			for strict in range(2):
				for json in range(2):
					process_result* old = 0
					for enabled in range(2):
						char** args = strv_new(10)
						int i = 0
						i = ast_test_arg(args, i, compiler)
						i = ast_test_arg(args, i, c"check")
						i = ast_test_arg(args, i, c"--quiet")
						i = ast_test_arg(args, i, c"--bool-ops")
						if (json): i = ast_test_arg(args, i, c"--json")
						if (strict): i = ast_test_arg(args, i, c"--strict")
						if (enabled == 0): i = ast_test_arg(args, i, c"--streaming")
						if (enabled): i = ast_test_arg(args, i, c"--ast-required")
						if (host): i = ast_test_arg(args, i, arch)
						i = ast_test_arg(args, i, source)
						process_result* result = ast_test_run(args, 0)
						if (enabled == 0): old = result
						else:
							assert_equal(strict, result.status)
							assert_equal(old.status, result.status)
							assert_strings_equal(old.stdout_text, result.stdout_text)
							assert_strings_equal(old.stderr_text, result.stderr_text)
							process_result_free(result)
					process_result_free(old)
	ast_test_store_diagnostics(c"int main():\n\tbool yes = true\n\tif yes & (0xffffffff == 1): return 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tbool yes = true\n\tif yes & false | missing: return 1\n\treturn 0\n")


void test_ast_bool_warning_implicit_calls():
	ast_test_store_diagnostics(c"int main():\n\tstring text = s\"x\"\n\tif (text == s\"x\") & true: return 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tbool[2] values\n\tif values[0] & true: return 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tif (list[int]{1}.length == 1) & true: return 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"struct R: bool yes\nint main():\n\tif (new R(true)).yes & true: return 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"struct R: bool yes\nint main():\n\tif R(true).yes & true: return 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"import lib.str\nstruct R:\n\tstring text\n\tbool yes\nint main():\n\tif R(c\"x\", true).yes & true: return 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"import lib.str\nint main():\n\tif (cast(string, c\"x\") == s\"x\") & true: return 1\n\treturn 0\n")


void test_ast_warning_events_are_required():
	for fixture in range(11):
		char* source = c"structures/hash_table_test.w"
		if (fixture == 1): source = c"tests/default_args_missing_warning_fixture.w"
		if (fixture == 2): source = c"tests/list_builtin_warning_fixture.w"
		if (fixture == 3): source = c"tests/map_default_warning_fixture.w"
		if (fixture == 4): source = c"tests/warning_fixture.w"
		if (fixture == 5): source = c"tests/type_system_warning_fixture.w"
		if (fixture == 6): source = c"tests/ndarray_index_warning_fixture.w"
		if (fixture == 7): source = c"tests/atomic_host_operand_error_fixture.w"
		if (fixture == 8): source = c"tests/limb_builtin_warning_fixture.w"
		if (fixture == 9): source = c"tests/array_cast_warning_fixture.w"
		if (fixture == 10): source = c"tests/cross_line_call_warning_fixture.w"
		for host in range(2):
			char* compiler = c"bin/wv2"
			char* arch = c"x86"
			if (host):
				compiler = c"bin/wv2_64"
				arch = c"x64"
			int errors = (fixture == 1) || (fixture == 2) || (fixture == 3) || (fixture == 4) || (fixture == 8) || (fixture == 10)
			if (errors == 0): ast_test_image_at(compiler, arch, source, 0)
			for strict in range(2):
				for json in range(2):
					process_result* old = 0
					for enabled in range(2):
						char** args = strv_new(9)
						int i = 0
						i = ast_test_arg(args, i, compiler)
						i = ast_test_arg(args, i, c"check")
						i = ast_test_arg(args, i, c"--quiet")
						if (json): i = ast_test_arg(args, i, c"--json")
						if (strict): i = ast_test_arg(args, i, c"--strict")
						if (enabled == 0): i = ast_test_arg(args, i, c"--streaming")
						if (enabled): i = ast_test_arg(args, i, c"--ast-required")
						if (host): i = ast_test_arg(args, i, arch)
						i = ast_test_arg(args, i, source)
						process_result* result = ast_test_run(args, 0)
						if (enabled == 0): old = result
						else:
							assert_equal(strict || errors, result.status)
							assert_equal(old.status, result.status)
							assert_strings_equal(old.stdout_text, result.stdout_text)
							assert_strings_equal(old.stderr_text, result.stderr_text)
							process_result_free(result)
					process_result_free(old)
	ast_test_store_diagnostics(c"int f(int a, int b): return a + b\nint main(): return f(c\"bad\", 0xffffffff)\n")
	ast_test_store_diagnostics(c"int f(int a, int b): return a + b\nint main(): return f(1) + f(c\"bad\", 0xffffffff)\n")
	ast_test_store_diagnostics(c"int main():\n\tint a = 0\n\tint b = 0\n\ta = b = c\"bad\"\n\treturn a\n")
	ast_test_store_diagnostics(c"int f(int a): return a\nint main(): return f(c\"bad\") + missing\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] a = new list[int]\n\ta.push(c\"bad\") + missing\n\treturn 0\n")

	ast_test_store_diagnostics(c"int main(): return mul_hi(c\"bad\", 0xffffffff)\n")
	ast_test_store_diagnostics(c"int main(): return mul_hi(c\"bad\", 1) + missing\n")
	ast_test_store_diagnostics(c"type F = fn(int) -> int\nint f(int x): return x\nint main():\n\tF* p = f\n\treturn p\n\t\t(0xffffffff)\n")
	ast_test_store_diagnostics(c"int main():\n\tint[] a = new int[2]\n\treturn cast(int, cast(char*, a)) + 0xffffffff\n")
	ast_test_store_diagnostics(c"import lib.ndarray\nint main():\n\tndi a = ndi_new2(1, 1)\n\treturn a[c\"bad\", 0xffffffff]\n")

void test_ast_continuation_expressions_are_required():
	char* path = ast_test_path(c"_long_comment.w")
	string_builder* source = string_new()
	string_append(source, c"int answer(): return 42\n# ")
	for i in range(18000): string_append_char(source, 'x')
	string_append(source, c"\nint main(): return answer() != 42\n")
	assert1(file_write_text(path, source.data))
	string_free(source)
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		for fixture in range(4):
			char** args = strv_new(7)
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--quiet")
			strv_set(args, 4, c"--ast-required")
			char* input = c"tests/ast_continuation_expression_fixture.w"
			if (fixture == 1): input = c"tests/shell_commands_test.w"
			if (fixture == 2): input = c"tests/warning_clean_fixture.w"
			if (fixture == 3): input = path
			if (host): strv_set(args, 5, c"x64")
			strv_set(args, 5 + host, input)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			assert_strings_equal(c"", result.stderr_text)
			process_result_free(result)
		char* arch = c"x86"
		if (host): arch = c"x64"
		ast_test_image_at(compiler, arch, path, 1)
	unlink(path)
	free(path)


void test_ast_propagation_expressions_are_required():
	for fixture in range(4):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_propagation_expression_fixture.w"
			if (fixture == 1): source = c"tests/result_propagate_test.w"
			if (fixture == 2): source = c"tests/generator_return_free_test.w"
			if (fixture == 3): source = c"tests/feature_combo_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"import lib.result\nint main(): return result_new_ok[int](1)?\n")
	ast_test_store_diagnostics(c"int main(): return 1?\n")
	ast_test_store_diagnostics(c"import lib.result\nwresult[int]* f(): return result_new_ok[int](result_new_ok[int](1)? + missing)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"import lib.result\nwresult[int]* f(wresult[int]* r):\n\tif r?: return result_new_ok[int](missing)\n\treturn r\nint main(): return 0\n")
	ast_test_store_diagnostics(c"import lib.result\nwresult[int]* f(wresult[bool]* r):\n\tint touched = 0\n\tdefer touched = 1\n\tif r? & true: return result_new_ok[int](touched)\n\treturn result_new_ok[int](0)\nint main(): return 0\n")


void test_ast_bare_callbacks_are_required():
	for fixture in range(3):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_bare_callback_expression_fixture.w"
			if (fixture == 1): source = c"libs/standard/distributed/raft_sweep_test.w"
			if (fixture == 2): source = c"tests/generics_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"type hook = fn(int) -> void\nint main():\n\thook value = cast(hook, missing)\n\tvalue(0)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main(): return never_defined[int](1)\n")
	ast_test_store_diagnostics(c"int main(): return future[int](1) + missing\nT future[T](T n): return n\n")
	ast_test_store_diagnostics(c"int main(): return future[int, int](1)\nT future[T](T n): return n\n")


void test_ast_list_it_expressions_are_required():
	for fixture in range(4):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_list_it_expression_fixture.w"
			if (fixture == 1): source = c"tests/list_it_test.w"
			if (fixture == 2): source = c"tests/golf_it_ints_test.w"
			if (fixture == 3): source = c"tests/golf_transpose_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1, 2}\n\tvalues.map(it + missing)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1, 2}\n\tvalues.filter(it * 1.5)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1, 2}\n\tvalues.sum(f\"{it}\")\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1, 2}\n\tvalues.map(it, 2)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1, 2}\n\tvalues.sorted_by(f\"{it}\")\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1, 2}\n\tvalues.map(it + values.map(it + missing).sum())\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] values = list[int]{1, 2}\n\tvalues.map(it + 2) + missing\n\treturn 0\n")


void test_ast_linkage_declarations_preserve_images():
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, c"tests/extern_data_test.w", 1)
		ast_test_image_at(compiler, arch, c"tests/float_abi_test.w", 1)
		ast_test_image_at(compiler, arch, c"tests/varargs_test.w", 1)
		ast_test_image_at(compiler, c"x64", c"tests/extern_alias_test.w", 1)
		ast_test_image_at(compiler, arch, c"tests/const_initializer_test.w", 1)
		ast_test_image_at(compiler, c"wasm", c"tests/wasm_extern_test.w", 0)
		for fixture in range(2):
			char* source = c"tests/extern_data_test.w"
			if (fixture): source = c"tests/const_initializer_test.w"
			process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
			assert_equal(0, result.status)
			if (fixture):
				assert_contains(result.stderr_text, c"AST enum values: ")
				assert_substring(result.stderr_text, c"AST enum values: 0\n", 0)
			else:
				assert_contains(result.stderr_text, c"AST extern objects: ")
				assert_substring(result.stderr_text, c"AST extern objects: 0\n", 0)
				assert_contains(result.stderr_text, c"AST extern functions: ")
				assert_substring(result.stderr_text, c"AST extern functions: 0\n", 0)
			process_result_free(result)
	ast_test_store_diagnostics(c"extern void object\nint main(): return 0\n")
	ast_test_store_diagnostics(c"extern int f(int x) = 3\nint main(): return 0\n")
	ast_test_store_diagnostics(c"struct R: int x\nextern R f()\nint main(): return 0\n")
	ast_test_store_diagnostics(c"enum E:\n	a = 1\n	b = a / 0\nint main(): return 0\n")


void test_ast_function_boundaries_preserve_frames():
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		for fixture in range(3):
			char* source = c"tests/ast_value_statement_fixture.w"
			char* counter = c"AST generators: "
			char* zero = c"AST generators: 0\n"
			char* target = arch
			if (fixture == 1):
				source = c"tests/script_fixture.w"
				counter = c"AST scripts: "
				zero = c"AST scripts: 0\n"
			if (fixture == 2):
				source = c"tests/ast_gpu_statement_fixture.w"
				target = c"x64"
				counter = c"AST kernels: "
				zero = c"AST kernels: 0\n"
			ast_test_image_at(compiler, target, source, 1)
			process_result* result = ast_test_compile(compiler, target, source, 0, 2, 1, 1)
			assert_equal(0, result.status)
			assert_contains(result.stderr_text, c"AST functions: ")
			assert_substring(result.stderr_text, c"AST functions: 0\n", 0)
			assert_contains(result.stderr_text, counter)
			assert_substring(result.stderr_text, zero, 0)
			if (fixture == 2):
				assert_contains(result.stderr_text, c"AST kernel parameters: ")
				assert_substring(result.stderr_text, c"AST kernel parameters: 0\n", 0)
			process_result_free(result)
		ast_test_image_at(compiler, arch, c"tests/ast_default_expression_fixture.w", 1)
		ast_test_image_at(compiler, arch, c"tests/ast_variadic_expression_fixture.w", 1)
	ast_test_store_diagnostics(c"int f(int x = 1, int y): return x + y\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f():\n	goto missing\nint main(): return 0\n")
	ast_test_store_diagnostics(c"import lib.cuda\nkernel K(int x = 2): pass\nint main(): return 0\n")
	ast_test_store_diagnostics(c"import lib.cuda\nkernel K(int x);\nint main(): return 0\n")
	ast_test_store_diagnostics(c"import lib.generator\ngenerator int g(int x = 2): yield x\nint main():\n	for int n in g(): return n - 2\n	return 1\n")
	ast_test_store_diagnostics(c"int value\nvalue = 1\nint f(): return 2\n")


void test_ast_global_declarations_own_layouts():
	char* source = c"tests/ast_global_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST globals: ")
		assert_substring(result.stderr_text, c"AST globals: 0\n", 0)
		assert_contains(result.stderr_text, c"AST global initializers: ")
		assert_substring(result.stderr_text, c"AST global initializers: 0\n", 0)
		assert_contains(result.stderr_text, c"AST thread locals: ")
		assert_substring(result.stderr_text, c"AST thread locals: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int[2] a = 1\nint main(): return 0\n")
	ast_test_store_diagnostics(c"struct R: int x\nR r = 1\nint main(): return 0\n")
	ast_test_store_diagnostics(c"float32 f = 1\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int mutable = 1\nint x = mutable\nint main(): return 0\n")
	ast_test_store_diagnostics(c"thread_local int x = 2\nint main(): return 0\n")
	ast_test_store_diagnostics(c"thread_local int[2] a\nint main(): return 0\n")


void test_ast_gpu_statements_preserve_marshalling():
	char* source = c"tests/ast_gpu_statement_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		ast_test_image_at(compiler, c"x64", source, 1)
		process_result* result = ast_test_compile(compiler, c"x64", source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST GPU launches: ")
		assert_substring(result.stderr_text, c"AST GPU launches: 0\n", 0)
		assert_contains(result.stderr_text, c"AST GPU loops: ")
		assert_substring(result.stderr_text, c"AST GPU loops: 0\n", 0)
		assert_contains(result.stderr_text, c"AST GPU header values: ")
		assert_substring(result.stderr_text, c"AST GPU header values: 0\n", 0)
		assert_contains(result.stderr_text, c"AST GPU captures: ")
		assert_substring(result.stderr_text, c"AST GPU captures: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"import lib.cuda\nkernel K(int* p): p[0] = 1\nint main():\n	launch K[1, 16]()\n	return 0\n")
	ast_test_store_diagnostics(c"import lib.cuda\nkernel K(int* p): p[0] = 1\nint main():\n	launch K[1, 16](c\"bad\")\n	return 0\n")
	ast_test_store_diagnostics(c"import lib.cuda\nstruct R: int x\nkernel K(int* p): p[0] = 1\nint main():\n	launch K[1, 16](R(1))\n	return 0\n")
	ast_test_store_diagnostics(c"import lib.cuda\nkernel K(int* p): p[0] = 1\nint main():\n	launch K[1, missing](0)\n	return 0\n")
	ast_test_store_diagnostics(c"import lib.cuda\nint main():\n	gpu for int i in range(1, 4, 2): pass\n	return 0\n")
	ast_test_store_diagnostics(c"import lib.cuda\nvoid f(int* p):\n	gpu for int i in range(2):\n		return\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int launch = 1\nint gpu = 2\nint main(): return launch + gpu - 3\n")


void test_ast_deferred_expressions_bind_at_exit():
	char* source = c"tests/ast_deferred_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST deferred expressions: ")
		assert_substring(result.stderr_text, c"AST deferred expressions: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n	int x = 1\n	defer x++\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	int x = 1\n	defer ++x\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	int x = 1\n	int y = 2\n	defer x, y = y, x\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	defer missing()\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	int x = 1\n	defer x = c\"bad\"\n	return x\n")


void test_ast_control_regions_and_scopes():
	char* source = c"tests/ast_scope_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST if regions: ")
		assert_substring(result.stderr_text, c"AST if regions: 0\n", 0)
		assert_contains(result.stderr_text, c"AST switch regions: ")
		assert_substring(result.stderr_text, c"AST switch regions: 0\n", 0)
		assert_contains(result.stderr_text, c"AST blocks: ")
		assert_substring(result.stderr_text, c"AST blocks: 0\n", 0)
		assert_contains(result.stderr_text, c"AST while loops: ")
		assert_substring(result.stderr_text, c"AST while loops: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n	if true:\n		int x = 1\n	return x\n")
	ast_test_store_diagnostics(c"int main():\n	{\n		int unused = 1\n	}\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	{\n		pass\n")
	ast_test_store_diagnostics(c"int main():\n	if true:\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	if true:\n		return 1\n		pass\n	else:\n		return 0\n")


void test_ast_loop_nodes_preserve_iteration():
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, c"tests/for_test.w", 1)
		ast_test_image_at(compiler, arch, c"tests/for_container_test.w", 1)
		ast_test_image_at(compiler, arch, c"tests/generator_return_free_test.w", 1)
		process_result* result = ast_test_compile(compiler, arch, c"tests/for_container_test.w", 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST range loops: ")
		assert_substring(result.stderr_text, c"AST range loops: 0\n", 0)
		assert_contains(result.stderr_text, c"AST cursor loops: ")
		assert_substring(result.stderr_text, c"AST cursor loops: 0\n", 0)
		assert_contains(result.stderr_text, c"AST iteration values: ")
		assert_substring(result.stderr_text, c"AST iteration values: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n	for i in range(): pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	for i in range(1, 2, 3, 4): pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	for i in range(missing): pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	for i in 1: pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	for i, x in range(3): pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	for i in enumerate(list[int]{1, 2}): pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	for int i in list[char*]{c\"bad\"}: pass\n	return 0\n")


void test_ast_switch_values_own_expression_roots():
	char* source = c"tests/switch_test.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST switch selectors: ")
		assert_substring(result.stderr_text, c"AST switch selectors: 0\n", 0)
		assert_contains(result.stderr_text, c"AST switch case values: ")
		assert_substring(result.stderr_text, c"AST switch case values: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n	switch 1.5:\n		default: pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	switch 1:\n		case c\"bad\": pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	switch 1:\n		case 1,: pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	switch 1:\n		default: pass\n		case 2: pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	switch 1: pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	switch missing:\n		default: pass\n	return 0\n")


void test_ast_guards_own_condition_roots():
	char* source = c"tests/ast_guard_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST conditional branches: ")
		assert_substring(result.stderr_text, c"AST conditional branches: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n	int x = 0\n	if (x = 1): return x\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	bool a = true\n	bool b = false\n	while (a & b): break\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	if missing: return 0\n	return 1\n")
	ast_test_store_diagnostics(c"int main():\n	while : pass\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	const int x = 1\n	if (x = 2): return x\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	if true:\n		pass\n	elif (1 + ): return 1\n	return 0\n")


void test_ast_local_declarations_own_initializers():
	char* source = c"tests/ast_declaration_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		ast_test_image_at(compiler, arch, c"tests/infer_test.w", 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST local declarations: ")
		assert_substring(result.stderr_text, c"AST local declarations: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n	int x = missing\n	return x\n")
	ast_test_store_diagnostics(c"int main():\n	x := missing\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	int x = c\"bad\"\n	return x\n")
	ast_test_store_diagnostics(c"void f(): return\nint main():\n	x := f()\n	return 0\n")
	ast_test_store_diagnostics(c"int f(): return 0\nint main():\n	x := f\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	x := 1\n	x := 2\n	return x\n")
	ast_test_store_diagnostics(c"int main():\n	int[3] x = 1\n	return 0\n")
	ast_test_store_diagnostics(c"int main():\n	const int x = 1\n	x = 2\n	return x\n")


void test_ast_constant_expressions_are_folded():
	char* source = c"tests/const_initializer_test.w"
	char* path = ast_test_path(c"_constants.w")
	string_builder* long_source = string_new()
	string_append(long_source, c"const int value = 0")
	for i in range(3000): string_append(long_source, c"+1")
	string_append(long_source, c"\nint main(): return value - 3000\n")
	assert1(file_write_text(path, long_source.data))
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		ast_test_image_at(compiler, arch, path, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST constant expressions: ")
		assert_substring(result.stderr_text, c"AST constant expressions: 0\n", 0)
		process_result_free(result)
	unlink(path)
	free(path)
	string_free(long_source)
	ast_test_store_diagnostics(c"const int broken = 2147483647 + 1\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = -2147483647 - 2\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = -(-2147483647 - 1)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 65536 * 65536\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 1 / 0\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 1 % 0\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 1 << 31\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 1 << -1\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 1 >> 32\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = (1 + 2\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = sizeof(int\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = missing\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 0x100000000 + 1\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 4294967296 + 1\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 1 / 0 + missing\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 1 / 0 + 4294967296\nint main(): return 0\n")
	ast_test_store_diagnostics(c"const int broken = 1\n+2\nint main(): return 0\n")


void test_ast_raw_statements_preserve_bytes():
	char* source = c"tests/ast_raw_statement_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST raw-asm statements: ")
		assert_substring(result.stderr_text, c"AST raw-asm statements: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\traw_asm(1)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\traw_asm(c\"\\x90\" 1)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\traw_asm(c\"\\q\")\n\treturn 0\n")
	ast_test_store_diagnostics(c"kernel bad(int* p):\n\traw_asm(c\"\\x90\")\nint main(): return 0\n")


void test_ast_goto_statements_resolve_labels():
	char* source = c"tests/goto_test.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST goto/label statements: ")
		assert_substring(result.stderr_text, c"AST goto/label statements: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tgoto missing\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\there:\n\there:\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tgoto 42\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tgoto target 42\n\ttarget:\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tgoto target\n\tpass\n\ttarget:\n\treturn 0\n")


void test_ast_expression_statements_own_roots():
	char* source = c"tests/ast_expression_statement_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST expression statements: ")
		assert_substring(result.stderr_text, c"AST expression statements: 0\n", 0)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tint a = 1\n\t++a + 2\n\treturn a\n")
	ast_test_store_diagnostics(c"int main():\n\tconst int a = 1\n\ta++\n\treturn a\n")
	ast_test_store_diagnostics(c"int main():\n\tint a = 1\n\ta, a = 0xffffffff, missing\n\treturn a\n")
	ast_test_store_diagnostics(c"void f(int n): pass\nint main():\n\tf(c\"bad\")\n\treturn 0\n")


void test_ast_value_statements_own_expressions():
	char* source = c"tests/ast_value_statement_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST return statements: ")
		assert_contains(result.stderr_text, c"AST yield statements: 1\n")
		process_result_free(result)
	ast_test_store_diagnostics(c"int f(): return c\"bad\"\nint main(): return 0\n")
	ast_test_store_diagnostics(c"struct A: int a\nstruct B: int b\nA f(): return B(1)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"import lib.generator\ngenerator int g():\n\tyield c\"bad\"\nint main(): return 0\n")
	ast_test_store_diagnostics(c"import lib.generator\ngenerator int g(): return 0xffffffff\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int main():\n\tyield 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main(): return 1 2\n")
	ast_test_store_diagnostics(c"int main(): return 1 + missing\n")


void test_ast_simple_statements_are_emitted():
	char* source = c"tests/ast_simple_statement_fixture.w"
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, source, 1)
		process_result* result = ast_test_compile(compiler, arch, source, 0, 2, 1, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST simple statements: ")
		assert_contains(result.stderr_text, c"AST debugger statements: 1\n")
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tbreak\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tcontinue\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tbreak 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tcontinue 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tpass 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tdebugger 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\twhile 1:\n\t\tbreak\n\t\tpass\n\treturn 0\n")
	ast_test_store_diagnostics(c"type pass = int\nint main():\n\tpass value = 0\n\treturn value\n")


void test_ast_near_limit_expressions_are_required():
	for fixture in range(2):
		char* source = c"tests/expression_nesting_clean_fixture.w"
		if (fixture): source = c"tests/ternary_nesting_clean_fixture.w"
		for host in range(2):
			char* compiler = c"bin/wv2"
			char* arch = c"x86"
			if (host):
				compiler = c"bin/wv2_64"
				arch = c"x64"
			ast_test_image_at(compiler, arch, source, 0)
			char** args = strv_new(7)
			int i = 0
			i = ast_test_arg(args, i, compiler)
			i = ast_test_arg(args, i, c"check")
			i = ast_test_arg(args, i, c"--json")
			i = ast_test_arg(args, i, c"--quiet")
			i = ast_test_arg(args, i, c"--ast-required")
			if (host): i = ast_test_arg(args, i, arch)
			i = ast_test_arg(args, i, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)

	char* path = ast_test_path(c"_wide_parallel.w")
	string_builder* source = string_from(c"int main():\n\tint[2] a\n\ta[0")
	for i in range(100): string_append(source, c"+0")
	string_append(source, c"], a[1")
	for i in range(100): string_append(source, c"+0")
	string_append(source, c"] = 12, 30\n\treturn a[0] + a[1] - 42\n")
	assert1(file_write_text(path, source.data))
	string_free(source)
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"x86"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		ast_test_image_at(compiler, arch, path, 1)
		char** args = strv_new(5)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--ast-required")
		if (host):
			strv_set(args, 3, arch)
			strv_set(args, 4, path)
		else: strv_set(args, 3, path)
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	unlink(path)
	free(path)


void test_ast_gpu_qualified_expressions_are_required():
	for fixture in range(4):
		for host in range(2):
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			char* source = c"tests/ast_gpu_qualified_expression_fixture.w"
			if (fixture == 1): source = c"tests/gpu_qualifier_ptx.w"
			if (fixture == 2): source = c"tests/gpu_qualifier_gpu.w"
			if (fixture == 3): source = c"tests/gpu_qualifier_ok_fixture.w"
			ast_test_image_at(compiler, c"x64", source, fixture != 2)
			char** args = strv_new(6)
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			strv_set(args, 4, c"x64")
			strv_set(args, 5, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tgpu int* p = cast(gpu int*, 0)\n\treturn p[0]\n")
	ast_test_store_diagnostics(c"int main():\n\tgpu int* p = cast(gpu int*, 0)\n\tp[0] = 7\n\treturn 0\n")
	ast_test_store_diagnostics(c"struct R:\n\tint n\nint main():\n\tgpu R* p = cast(gpu R*, 0)\n\treturn p.n\n")
	ast_test_store_diagnostics(c"void f(int* p): pass\nint main():\n\tgpu int* p = cast(gpu int*, 0)\n\tf(p)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tgpu int* p = cast(gpu int*, 0)\n\tint* q = p\n\treturn q == 0\n")
	ast_test_store_diagnostics(c"int main():\n\tcast(gpu uint16**, 0) + missing\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tcast(gpu int, 0)\n\treturn 0\n")
	ast_test_store_diagnostics(c"kernel bad(gpu int* p):\n\tp[0] = missing\nint main(): return 0\n")

	ast_test_store_diagnostics(c"int main():\n\tgpu int* p = cast(gpu int*, 0)\n\treturn cast(int, &p[p[0]])\n")
	ast_test_store_diagnostics(c"int main():\n\tgpu int* p = cast(gpu int*, 0)\n\treturn cast(int, &p[0]) + missing\n")
	ast_test_store_diagnostics(c"struct R: int n\nint main():\n\tgpu R* p = cast(gpu R*, 0)\n\treturn cast(int, &p.n) + missing\n")

void test_ast_device_expressions_are_required():
	for fixture in range(3):
		for host in range(2):
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			char* source = c"tests/ast_device_expression_fixture.w"
			if (fixture == 1): source = c"tests/gpu_ptx_emit.w"
			if (fixture == 2): source = c"tests/cuda_gpu.w"
			ast_test_image_at(compiler, c"x64", source, fixture == 1)
			char** args = strv_new(6)
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			strv_set(args, 4, c"x64")
			strv_set(args, 5, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"kernel bad(int* p):\n\tp[0] = thread_idx(1)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"kernel bad(int* p):\n\tatomic_cas(p, 1, 2)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"kernel bad(int* p):\n\tatomic_add(1, 2)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"kernel bad(float32* p):\n\tatomic_min(p, 1.0)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"kernel bad(int* p):\n\tp[0] = gpu_shared_f32(0)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"kernel bad(int* p):\n\tp[0] = gpu_shared_f32(12289)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"kernel bad(int* p):\n\tp[0] = gpu_shared_f32(2 + 3)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int global\nkernel bad(int* p):\n\tp[0] = global\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(): return 0\nkernel bad(int* p):\n\tp[0] = f()\nint main(): return 0\n")
	ast_test_store_diagnostics(c"import lib.cuda\nvoid bad(int* p, int n):\n\tgpu for i in range(4):\n\t\tn = i\nint main(): return 0\n")
	ast_test_store_diagnostics(c"import lib.cuda\nvoid bad(int* p, int n):\n\tgpu for i in range(4):\n\t\tp[i] = n + missing\nint main(): return 0\n")


void test_ast_qualified_expressions_are_required():
	for fixture in range(3):
		for host in range(2):
			char** args = strv_new(5)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_qualified_expression_fixture.w"
			if (fixture == 1): source = c"tests/import_alias_type_test.w"
			if (fixture == 2): source = c"tests/import_test.w"
			strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"import tests.import_alias_type_helper as types\nint local(): return 0\nint main():\n\ttypes.missing()\n\treturn 0\n")
	ast_test_store_diagnostics(c"import tests.import_alias_type_helper as types\nint local(): return 0\nint main():\n\ttypes.local()\n\treturn 0\n")
	ast_test_store_diagnostics(c"import tests.import_alias_type_helper as types\nint local(): return 0\nint main():\n\tcast(types.alias_type_helper_value, 1)\n\treturn 0\n")
	ast_test_store_diagnostics(c"import tests.import_alias_type_helper as types\nint local(): return 0\nint main():\n\tnew types.missing\n\treturn 0\n")
	ast_test_store_diagnostics(c"import tests.import_alias_type_helper as types\nint local(): return 0\nint main():\n\tsizeof(types.local)\n\treturn 0\n")
	ast_test_store_diagnostics(c"import tests.import_alias_type_helper as types\nint local(): return 0\nint main():\n\ttypes.alias_point(1, missing)\n\treturn 0\n")
	ast_test_store_diagnostics(c"import tests.import_alias_type_helper as types\nint local(): return 0\nint main():\n\ttypes.alias_type_helper_value() + missing\n\treturn 0\n")


void test_ast_template_formats_are_required():
	for fixture in range(3):
		for host in range(2):
			int count = 5
			if (fixture == 2): count = 6
			char** args = strv_new(count)
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			char* source = c"tests/ast_template_format_expression_fixture.w"
			if (fixture == 1): source = c"tests/template_format_test.w"
			if (fixture == 2):
				source = c"tests/template_format_float64_test.w"
				strv_set(args, 4, c"x64")
				strv_set(args, 5, source)
			else: strv_set(args, 4, source)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{1:q}\"\n\treturn text.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{1:.2}\"\n\treturn text.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{c\"text\":05}\"\n\treturn text.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{c\"text\":x}\"\n\treturn text.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{1:4097}\"\n\treturn text.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{1:.61}\"\n\treturn text.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{1:.}\"\n\treturn text.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{1:04d}\" + missing\n\treturn text.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{1:03\"\n\treturn text.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring text = f\"{(1 + 2):03}\"\n\treturn text.length\n")


void test_ast_templates_are_required():
	ast_test_store_diagnostics(c"int f(char* p): return p[0]\nint main(): return (f(f\"{1}\"))\n")
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_template_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tstring s = (f\"{4294967296}\")\n\treturn s.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = (f\"{missing}\")\n\treturn s.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = (f\"\\xzz\")\n\treturn s.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = (f\"{1:04d}\")\n\treturn s.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = (f\"{1 + }\")\n\treturn s.length\n")
	ast_test_store_diagnostics(c"int main():\n\tint* p = 0\n\tstring s = (f\"{p}\")\n\treturn s.length\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = (f\"\")\n\treturn s.length\n")


void test_ast_hash_methods_are_required():
	char* path = ast_test_path(c"_hash_methods.w")
	assert1(file_write_text(path, c"int main():\n\tmap[int, int] m = new map[int, int]\n\tm[1] = 2\n\tint n = m.get(1) + m.get(9, 3)\n\tm.remove(1)\n\tm.free()\n\tset[int] s = new set[int]\n\ts.add(2)\n\ts.remove(2)\n\ts.free()\n\treturn n - 5\n"))
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, path)
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	unlink(path)
	free(path)
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m.get(c\"bad\", 0))\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m.get(1, c\"bad\"))\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m.get())\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int main():\n\tset[int] s = new set[int]\n\tif 1: (s.add(c\"bad\"))\n\treturn 0\n")


void test_ast_wide_calls_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_wide_call_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int f(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j, int k, int l): return l\nint main(): return (f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11))\n")


void test_ast_increment_statements_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_increment_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tint n = 0\n\treturn (++n)\n")
	ast_test_store_diagnostics(c"int main():\n\tint n = 0\n\treturn (n++)\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] m = new map[int, int]\n\t++m[1]\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = s\"hi\"\n\ts.length++\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tconst int n = 1\n\t++n\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\t(1 + 2)++\n\treturn 0\n")


void test_ast_parallel_roots_are_required():
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, c"tests/ast_parallel_expression_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tint a\n\tint b\n\ta, b = 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tint a\n\tint b\n\ta, b = 1, 2, 3\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] m = new map[int, int]\n\tint a\n\tm[1], a = 2, 3\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = s\"hi\"\n\tint a\n\ts.length, a = 2, 3\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tint a\n\tint b\n\ta, b = 1, c\"bad\"\n\treturn 0\n")


void test_ast_map_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_map.w")
	assert1(file_write_text(path, c"int main():\n\tmap[int, int] m = new map[int, int]\n\tif 1: (m[1] = 2)\n\tif 1: (m[1] += 3)\n\tint n = (m[1])\n\tbool found = (1 in m)\n\treturn n + found\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* result = ast_test_compile(compiler, c"x64", path, 0, 1, 0, 1)
		assert_equal(0, result.status)
		assert_contains(result.stderr_text, c"AST expressions: 4\n")
		process_result_free(result)
	unlink(path)
	free(path)
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] m = new map[int, int]\n\tif 1: (m[1] = c\"bad\")\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] m = new map[int, int]\n\tif 1: ((m[1]) = 2)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m[c\"bad\"])\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (c\"bad\" in m)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(int n): return (1 in n)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(list[string] xs): return (s\"x\" in xs)\nint main(): return 0\n")


void test_ast_record_return_roots_are_required():
	char* path = ast_test_path(c"_record_return.w")
	assert1(file_write_text(path, c"struct R:\n\tint x\nR make(int n):\n\tR r\n\tr.x = n\n\treturn r\nint get(R r): return r.x\nint main():\n\tR r = make(1)\n\tr = make(2)\n\treturn get(make(3)) + make(4).x\n"))
	for host in range(2):
		char** args = strv_new(5)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--json")
		strv_set(args, 3, c"--ast-required")
		strv_set(args, 4, path)
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	unlink(path)
	free(path)


void test_ast_record_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_record.w")
	assert1(file_write_text(path, c"struct R:\n\tint x\nint f(R r): return r.x\nint main():\n\tR a\n\ta.x = 7\n\tR b = (a)\n\tif 1: (b = a)\n\treturn (f(b))\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 0, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 3\n")
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_store_diagnostics(c"struct A:\n\tint x\nstruct B:\n\tint y\nint main():\n\tA a\n\tB b\n\tif 1: (a = b)\n\treturn 0\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint f(R a): return a.x\nint main(): return (f(3))\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main():\n\tR a\n\tR b\n\tif 1: (a += b)\n\treturn 0\n")


void test_ast_metadata_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_metadata.w")
	assert1(file_write_text(path, c"int f(string s): return (s.length + s.data[0])\nint g(list[int] xs): return (xs.length)\nint h(int p): return (*p)\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 3\n")
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_store_diagnostics(c"int main():\n\tstring s = s\"ab\"\n\t(s.length) = 7\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = s\"ab\"\n\tif 1: (s.length = 7)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = s\"ab\"\n\tif 1: (s.data = 0)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = s\"ab\"\n\t(s.length) += 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tlist[int] xs = new list[int]\n\tstring s = s\"\"\n\tif 1: (xs[s.length] = 7)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tint[2] xs\n\tstring s = s\"\"\n\tif 1: (xs[s.length] = 7)\n\treturn xs[0]\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] xs = new map[int, int]\n\t(xs.length)++\n\treturn 0\n")


void test_ast_multiline_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_multiline.w")
	assert1(file_write_text(path, c"int f(int a): return (a +\n\t2 # comment\n\t+ 3)\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 1\n")
		process_result_free(ast)
		char** args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, c"tests/ast_multiline_expression_fixture.w")
		ast = ast_test_run(args, 0)
		assert_equal(0, ast.status)
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"int main(): return (1 +\n 2)\n")
	ast_test_diagnostics(c"int main(): return (1 +\n\t0xffffffff)\n")
	ast_test_diagnostics(c"int main(): return (1 + # comment\n\t4294967296)\n")
	ast_test_diagnostics(c"int f(int n): return n\nint main(): return (f\n\t(1))\n")
	ast_test_diagnostics(c"int main(): return (2\n\t* 3)\n")
	ast_test_diagnostics(c"int main(): return (2 +\n\t3")
	ast_test_diagnostics(c"int main(): return (2 + # no final newline")
	ast_test_diagnostics(c"int main(): return (2 /* newline\n unclosed")


void test_ast_allocation_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_allocation.w")
	assert1(file_write_text(path, c"import lib.memory\nstruct R:\n\tint x\nint f(): return (cast(int, new R))\nint size(): return (sizeof(R**))\nint stub(int p): return (repl_setjmp(p))\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 3\n")
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"int main(): return (sizeof(missing))\n")
	ast_test_diagnostics(c"int main(): return (sizeof(int** + 0xffffffff))\n")
	ast_test_diagnostics(c"int main(): return (sizeof(float64))\n")
	ast_test_diagnostics(c"import lib.memory\nstruct R:\n\tint x\nint main(): return (cast(int, new R) + 0xffffffff)\n")
	ast_test_diagnostics(c"import lib.memory\nint main(): return (cast(int, new missing))\n")
	ast_test_diagnostics(c"import lib.memory\nstruct R:\n\tint x\nint main(): return (cast(int, new R(1, missing)))\n")


void test_ast_default_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_default.w")
	assert1(file_write_text(path, c"int f(int n = 42): return n\nint main(): return (f()) - 42\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 1\n")
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"int f(int a, int b = 2): return a + b\nint main(): return (f())\n")
	ast_test_diagnostics(c"int f(int a = 1): return a\nint main(): return (f(1, 2))\n")
	ast_test_diagnostics(c"int f(int a = 1): return a\nint main(): return (f(c\"wrong\"))\n")


void test_ast_callback_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_callback.w")
	assert1(file_write_text(path, c"type F = fn(int) -> int\nint f(int n): return n + 1\nint call(F* p): return (p(41))\nint main():\n\tF* p = (f)\n\tint raw = (cast(int, f))\n\tif ((p == f)): raw = raw + 0\n\tif 1: (p = f)\n\treturn (call(f)) - 42\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 6\n")
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"int f(int n): return n\nint main(): return (cast(uint8, f))\n")
	ast_test_diagnostics(c"type F = fn(int) -> int\nint f(int a, int b): return a + b\nint main():\n\tF* p = 0\n\tif 1: (p = f)\n\treturn 0\n")
	ast_test_diagnostics(c"type F = fn(int) -> int\nint main():\n\tF* p = 0\n\treturn (p(1, 2))\n")
	ast_test_diagnostics(c"type F = fn(int) -> int\nint main():\n\tF* p = 0\n\treturn (p(c\"wrong\"))\n")
	ast_test_diagnostics(c"type F = fn(int) -> int\nint f(int n): return n\nint g(F* p, int b): return p(b)\nint main(): return (g(f, 0xffffffff))\n")
	ast_test_diagnostics(c"int f(int n): return n\nint main(): return (f(f))\n")


void test_ast_word_address_index_hits():
	char* path = ast_test_path(c"_word_address.w")
	assert1(file_write_text(path, c"int f(int p, int i): return (p[i])\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 1\n")
		process_result_free(ast)
	unlink(path)
	free(path)


void test_ast_call_containing_bool_chains():
	char* path = ast_test_path(c"_bool_chain.w")
	assert1(file_write_text(path, c"bool f(bool b): return b\nint main():\n\tif (f(true) & true & false): return 1\n\treturn 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* hit = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, hit.status)
		assert_contains(hit.stderr_text, c"AST expressions: 1\n")
		process_result_free(hit)
		process_result* old = 0
		for enabled in range(3):
			char** args = strv_new(8)
			int i = 0
			i = ast_test_arg(args, i, compiler)
			i = ast_test_arg(args, i, c"check")
			i = ast_test_arg(args, i, c"--json")
			i = ast_test_arg(args, i, c"--quiet")
			i = ast_test_arg(args, i, c"--bool-ops")
			if (enabled == 1): i = ast_test_arg(args, i, c"--ast-expressions")
			if (enabled == 2): i = ast_test_arg(args, i, c"--ast-full-expressions")
			strv_set(args, i, path)
			process_result* result = ast_test_run(args, 0)
			if (enabled == 0): old = result
			else:
				assert_equal(old.status, result.status)
				assert_strings_equal(old.stdout_text, result.stdout_text)
				assert_strings_equal(old.stderr_text, result.stderr_text)
				process_result_free(result)
		assert_contains(old.stdout_text, c"does not short-circuit")
		process_result_free(old)
	unlink(path)
	free(path)
	# A later call must not suppress the warning on a pure prefix.
	ast_test_diagnostics(c"bool f(bool b): return b\nint main():\n\tif (true & false & f(true)): return 1\n\treturn 0\n")
	ast_test_diagnostics(c"bool f(bool b): return b\nint main():\n\tif (true | false | f(true)): return 1\n\treturn 0\n")


void test_ast_expression_crosses_input_buffer_boundary():
	char* path = ast_test_path(c"_boundary.w")
	char* prefix = c"\nint f(int a): return "
	string_builder* source = string_from(c"#")
	for i in range(8180 - 1 - strlen(prefix)): string_append_char(source, 'x')
	string_append(source, prefix)
	string_append(source, c"(a + 2 /* crosses the input window */)\nint main(): return 0\n")
	assert1(file_write_text(path, source.data))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 1\n")
		process_result_free(ast)
		ast_test_image_at(compiler, c"x64", path, 1)
	ast_test_diagnostics(source.data)
	string_free(source)
	unlink(path)
	free(path)


void test_ast_statement_lookahead_crosses_input_buffer_boundary():
	char* path = ast_test_path(c"_lookahead_boundary.w")
	for position in range(7):
		int offset = 8182 + position
		if (position >= 4): offset = 8205 + position
		string_builder* source = string_from(c"int main():\n\tint allowed = 0\n\t#")
		while (source.length < offset - 2): string_append_char(source, 'x')
		string_append(source, c"\n\tallowed = 1\n\treturn allowed - 1\n")
		assert1(file_write_text(path, source.data))
		for host in range(2):
			char* compiler = c"bin/wv2"
			if (host): compiler = c"bin/wv2_64"
			char** args = strv_new(5)
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--ast-required")
			strv_set(args, 4, path)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			process_result_free(result)
			ast_test_image_at(compiler, c"x64", path, 1)
		string_free(source)
	unlink(path)
	free(path)


void test_ast_expression_token_crosses_input_buffer_boundary():
	char* path = ast_test_path(c"_token_boundary.w")
	char* prefix = c"\nint f(int cross_window_name): return "
	string_builder* source = string_from(c"#")
	for i in range(8188 - 1 - strlen(prefix)): string_append_char(source, 'x')
	string_append(source, prefix)
	string_append(source, c"cross_window_name + 1\nint main(): return f(41) - 42\n")
	assert1(file_write_text(path, source.data))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		char** args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-audit")
		strv_set(args, 5, path)
		process_result* audit = ast_test_run(args, 0)
		assert_equal(0, audit.status)
		assert_substring(audit.stderr_text, path, 0)
		process_result_free(audit)
		ast_test_image_at(compiler, c"x64", path, 1)
	ast_test_diagnostics(source.data)
	string_free(source)
	unlink(path)
	free(path)


void test_ast_utf8_token_crosses_input_buffer_boundary():
	char* path = ast_test_path(c"_utf8_boundary.w")
	char* prefix = c"\nint f(int 🎉): return "
	string_builder* source = string_from(c"#")
	for i in range(8191 - 1 - strlen(prefix)): string_append_char(source, 'x')
	string_append(source, prefix)
	string_append(source, c"🎉 + 1\nint main(): return f(41) - 42\n")
	assert1(file_write_text(path, source.data))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		char** args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-audit")
		strv_set(args, 5, path)
		process_result* audit = ast_test_run(args, 0)
		assert_equal(0, audit.status)
		assert_substring(audit.stderr_text, path, 0)
		process_result_free(audit)
		ast_test_image_at(compiler, c"x64", path, 1)
	ast_test_diagnostics(source.data)
	string_free(source)
	unlink(path)
	free(path)


void test_ast_large_literal_crosses_input_buffer_boundary():
	char* path = ast_test_path(c"_large_literal_boundary.w")
	char* prefix = c"\nchar* f(): return c\""
	string_builder* source = string_from(c"#")
	for i in range(4098 - 1 - strlen(prefix)): string_append_char(source, 'x')
	string_append(source, prefix)
	for i in range(4096): string_append_char(source, 'a')
	string_append(source, c"\"\nint main(): return f()[4095] - 'a'\n")
	assert1(file_write_text(path, source.data))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		char** args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-audit")
		strv_set(args, 5, path)
		process_result* audit = ast_test_run(args, 0)
		assert_equal(0, audit.status)
		assert_substring(audit.stderr_text, path, 0)
		process_result_free(audit)
		ast_test_image_at(compiler, c"x64", path, 1)
	ast_test_diagnostics(source.data)
	string_free(source)
	unlink(path)
	free(path)


void test_ast_pointer_type_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_pointer_type.w")
	assert1(file_write_text(path, c"struct R:\n\tint x\nint f(int p): return ((*cast(R*, p)).x)\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 1\n")
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"struct R:\n\tint x\nint f(int p): return (cast(R**, p) + missing)\nint main(): return 0\n")
	ast_test_diagnostics(c"struct R:\n\tint x\nint f(int p): return (0xffffffff + cast(R*, p))\nint main(): return 0\n")
	ast_test_diagnostics(c"struct R:\n\tint x\nint f(int p): return (cast(R*, p) + 0xffffffff)\nint main(): return 0\n")
	ast_test_diagnostics(c"struct R:\n\tint x\nint f(int p): return (cast(R**, p) + )\nint main(): return 0\n")


void test_ast_list_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_list.w")
	assert1(file_write_text(path, c"int f(list[int] a): return (a[0] + a[1])\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 1\n")
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"int f(list[int] a): return (a[missing])\nint main(): return 0\n")
	ast_test_diagnostics(c"int f(list[int] a): return (a[0xffffffff])\nint main(): return 0\n")
	ast_test_diagnostics(c"int f(list[int] a): return (a[1 + ])\nint main(): return 0\n")


void test_ast_comment_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_comment.w")
	assert1(file_write_text(path, c"int f(int a): return (a /* left */ + 2 /* final */)\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 1\n")
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"int main(): return (1 + /* unclosed\n")
	ast_test_diagnostics(c"int main(): return (1 /* closed */ + )\n")
	ast_test_diagnostics(c"int main(): return (0xffffffff /* warning */ + 1)\n")
	ast_test_diagnostics(c"int main():\n\tint x = 1 /* final */\n    return x\n")
	ast_test_diagnostics(c"int main():\n\tint x = 1 /* final */\n\t/* boundary */\n\t(println(42))\n\treturn x\n")
	ast_test_diagnostics(c"int main(): return (1 /*/ \" */ + 2)\n")


void test_ast_buffer_expression_hits_and_bounds():
	char* path = ast_test_path(c"_buffer.w")
	char* output = ast_test_path(c"_buffer")
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		assert1(file_write_text(path, c"int main():\n\tint[2] a\n\ta[0] = 20\n\ta[1] = 22\n\treturn (a[0] + a[1])\n"))
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 1\n")
		process_result_free(ast)
		for index in range(2):
			char* source = c"int main():\n\tint[2] a\n\treturn (a[2])\n"
			if (index): source = c"int main():\n\tint[2] a\n\treturn (a[-1])\n"
			assert1(file_write_text(path, source))
			for enabled in range(1, 3):
				ast = ast_test_compile(compiler, c"x64", path, output, enabled, 0, 0)
				assert_equal(0, ast.status)
				process_result_free(ast)
				char** args = strv_new(1)
				strv_set(args, 0, output)
				ast = ast_test_run(args, 0)
				assert1(ast.status != 0)
				if (index): assert_contains(ast.stderr_text, c"index out of range: index -1, length 2")
				else: assert_contains(ast.stderr_text, c"index out of range: index 2, length 2")
				process_result_free(ast)
	unlink(path)
	unlink(output)
	free(path)
	free(output)
	ast_test_diagnostics(c"int main():\n\tint[2] a\n\t(a.length) = 3\n\treturn 0\n")
	ast_test_diagnostics(c"int main():\n\tint[2] a\n\treturn (a[missing])\n")
	ast_test_diagnostics(c"int main():\n\tint[2] a\n\treturn (a[1 + ])\n")


int ast_test_emitted_count(char* stats):
	char* prefix = c"AST expressions: "
	int i = 0
	while (stats[i]):
		int j = 0
		while (prefix[j] && (stats[i + j] == prefix[j])): j = j + 1
		if (prefix[j] == 0): return atoi(stats + i + j)
		i = i + 1
	return -1


void test_ast_print_expression_diagnostics_and_hits():
	ast_test_diagnostics(c"int main():\n\t(print())\n\treturn 0\n")
	ast_test_diagnostics(c"int main():\n\t(println(1, 2))\n\treturn 0\n")
	ast_test_diagnostics(c"int main():\n\tfloat64 x = 1.5\n\t(println(x))\n\treturn 0\n")
	ast_test_diagnostics(c"int main():\n\tint* p = 0\n\t(println(p))\n\treturn 0\n")
	ast_test_diagnostics(c"int main():\n\t(println(0xffffffff))\n\treturn 0\n")
	char* path = ast_test_path(c"_print.w")
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		assert1(file_write_text(path, c"int main():\n\tif 1: println(42)\n\tif 1: println()\n\treturn 0\n"))
		process_result* baseline = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, baseline.status)
		int base_count = ast_test_emitted_count(baseline.stderr_text)
		assert1(base_count >= 0)
		assert1(file_write_text(path, c"int main():\n\tif 1: (println(42))\n\tif 1: (println())\n\treturn 0\n"))
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_equal(base_count + 2, ast_test_emitted_count(ast.stderr_text))
		process_result_free(baseline)
		process_result_free(ast)
	unlink(path)
	free(path)


void test_ast_expression_analysis_queries():
	char*[3] commands
	commands[0] = c"symbols"
	commands[1] = c"deps"
	commands[2] = c"defhash"
	for fixture in range(2):
		char* source = c"tests/ast_expression_fixture.w"
		if (fixture): source = c"tests/ast_logic_expression_fixture.w"
		for i in range(3):
			process_result* old = ast_test_query(commands[i], 0, source)
			process_result* ast = ast_test_query(commands[i], 1, source)
			assert_equal(0, old.status)
			assert_equal(0, ast.status)
			assert_strings_equal(old.stdout_text, ast.stdout_text)
			assert_strings_equal(old.stderr_text, ast.stderr_text)
			process_result_free(old)
			process_result_free(ast)


process_result* ast_test_repl(char* repl, int enabled, char* script):
	char** args = strv_new(3)
	strv_set(args, 0, repl)
	if (enabled < 2): strv_set(args, 1, c"--streaming")
	if (enabled == 1): strv_set(args, 2, c"--ast-expressions")
	if (enabled == 2): strv_set(args, 1, c"--ast-full-expressions")
	# S2.4: the REPL lowering from the retained forest.
	if (enabled == 3): strv_set(args, 1, c"--ast-emit-retained")
	return ast_test_run(args, script)


void test_ast_expression_repl_recovery():
	char* script = c"(6 * 7)\n(4294967296 + 1)\n(1 + )\nint keep = (5 * 9)\nkeep + (2 * 3)\n(keep) = 23\n(keep + 7)\nint keep = 60\n(keep + 3)\nint old(): return (keep + 4)\n(keep + missing)\n(old())\nint callee(int n): return n + 1\nint caller(int n): return (callee(n) * 2)\n(caller(20))\nint callee(int n): return n + 3\n(caller(20))\n(1.5 + 2.5)\n(1e+ + 2)\n(caller(20))\nint* nil = 0\n(nil && nil[0])\n(!nil || *nil)\n(2 < 3 && caller(20) == 46)\n(false && missing)\n(caller(20) >= 46)\nbool yes = true\n(yes)\n(!yes)\nstruct AstPointer: int x\n(cast(AstPointer**, 0) + missing)\n(cast(AstPointer**, 0) == 0)\n(cast(AstPointer***, 0) + )\n(cast(AstPointer***, 0) == 0)\n:reset\n(8 * 9)\n:quit\n"
	for host in range(2):
		char* repl = c"bin/ast_repl"
		if (host): repl = c"bin/ast_repl64"
		process_result* old = ast_test_repl(repl, 0, script)
		for enabled in range(1, 4):
			process_result* ast = ast_test_repl(repl, enabled, script)
			assert_equal(0, ast.status)
			assert_equal(old.status, ast.status)
			assert_strings_equal(old.stdout_text, ast.stdout_text)
			assert_contains(ast.stdout_text, c"42")
			assert_contains(ast.stdout_text, c"51")
			assert_contains(ast.stdout_text, c"72")
			assert_contains(ast.stdout_text, c"30")
			assert_contains(ast.stdout_text, c"63")
			assert_contains(ast.stdout_text, c"64")
			assert_contains(ast.stdout_text, c"46")
			assert_contains(ast.stderr_text, c"integer literal has more than 32 significant bits")
			process_result_free(ast)
		process_result_free(old)


void test_ast_expression_debugger_eval():
	char* path = ast_test_path(c".w")
	assert1(file_write_text(path, c"int main():\n\tint answer = (6 * 7)\n\tdebugger\n\treturn answer != 42\nint dbg_twice(int n): return n * 2\n"))
	for host in range(2):
		for enabled in range(4):
			char** args = strv_new(4)
			char* dbg_path = c"bin/wdbg"
			if (host): dbg_path = c"bin/wdbg64"
			strv_set(args, 0, dbg_path)
			strv_set(args, 1, path)
			if (enabled < 2): strv_set(args, 2, c"--streaming")
			if (enabled == 1): strv_set(args, 3, c"--ast-expressions")
			if (enabled == 2): strv_set(args, 2, c"--ast-full-expressions")
			if (enabled == 3): strv_set(args, 2, c"--ast-emit-retained")
			process_result* result = ast_test_run(args, c"p answer\np (answer + 5)\np (dbg_twice(answer) + 1)\np (1.5 + 2.5)\np (answer > 40 && dbg_twice(answer) == 84)\np (answer + missing)\np (5 + 6 * 7)\np (4294967296 + 1)\np (6 * 7)\nc\n")
			assert_equal(0, result.status)
			assert_contains(result.stdout_text, c"answer = 42")
			assert_contains(result.stdout_text, c"wdbg> = 47")
			assert_contains(result.stdout_text, c"wdbg> = 85")
			assert_contains(result.stdout_text, c"wdbg> = 42")
			assert_contains(result.stdout_text, c".w:3)")
			assert_contains(result.stderr_text, c"integer literal has more than 32 significant bits")
			process_result_free(result)
	unlink(path)
	free(path)


void test_ast_first_use_container_diagnostics():
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main(): return (list[R]{R(1)}.length + missing)\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main(): return (sizeof(list[R]**) + missing)\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main(): return (list[R]{R(4294967296)}.length)\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main(): return (list[R]{c\"bad\"}.length)\n")
	ast_test_store_diagnostics(c"struct R:\n\tint[2] x\nint main(): return (sizeof(list[R]))\n")
	ast_test_store_diagnostics(c"struct R:\n\tint[2] x\nint main(): return (sizeof(map[int, R]))\n")
	ast_test_store_diagnostics(c"int main(): return (sizeof(list[void]))\n")
	ast_test_store_diagnostics(c"int main(): return (sizeof(map[int, void]))\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main(): return (new map[int, R]).values(1).length\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main(): return ((new map[int, R]).values().length + missing)\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nT id[T](T v): return v\nint main(): return (id[list[R]](list[R]{R(1)}).length + missing)\n")


void test_ast_map_default_hits_and_diagnostics():
	char* path = ast_test_path(c"_map_default.w")
	assert1(file_write_text(path, c"int factory(): return 42\nmap[int, int] f(): return (new map[int, int](factory))\nmap[int, list[int]] g(): return (new map[int, list[int]]())\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 2\n")
		process_result_free(ast)
		char** args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, path)
		ast = ast_test_run(args, 0)
		assert_equal(0, ast.status)
		process_result_free(ast)
		args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, c"tests/ast_map_default_fixture.w")
		ast = ast_test_run(args, 0)
		assert_equal(0, ast.status)
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"int main(): return (cast(int, new map[int, int]()))\n")
	ast_test_diagnostics(c"int main(): return (cast(int, new map[int, int](c\"bad\")))\n")
	ast_test_diagnostics(c"int bad(): return 42\nint main(): return (cast(int, new map[int, char*](bad)))\n")
	ast_test_diagnostics(c"int main(): return (cast(int, new map[int, list[int]](0)))\n")
	ast_test_diagnostics(c"struct R:\n\tint x\nint main(): return (cast(int, new map[int, R](0)))\n")
	ast_test_diagnostics(c"int main(): return (cast(int, new map[int, int](0xffffffff)))\n")
	ast_test_diagnostics(c"int main(): return (cast(int, new map[int, int](1, 2)))\n")


void test_ast_value_constructor_hits_and_diagnostics():
	char* path = ast_test_path(c"_value_constructor.w")
	assert1(file_write_text(path, c"struct R:\n\tint x\nstruct S:\n\tR child\n\tint tag\nR make(int n): return R(n)\nint get(R r): return r.x\nint main():\n\tR r = R(1)\n\tr = R(x: 2)\n\tS s = S(make(3), 4)\n\tS* p = new S(R(5), 6)\n\treturn get(R(7)) + R(8).x + s.child.x + p.tag\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		char** args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, path)
		process_result* ast = ast_test_run(args, 0)
		assert_equal(0, ast.status)
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"struct R:\n\tint x\nint main(): return (R(0xffffffff).x)\n")
	ast_test_diagnostics(c"struct R:\n\tint x\nint main(): return (R(1, 2).x)\n")
	ast_test_diagnostics(c"struct R:\n\tint x\nint main(): return (R(missing: 1).x)\n")
	ast_test_store_diagnostics(c"struct R:\n\tint x\nint main():\n\tR r\n\tif 1: (r = R(c\"bad\"))\n\treturn 0\n")


void test_ast_heap_constructor_hits_and_diagnostics():
	char* path = ast_test_path(c"_constructor.w")
	assert1(file_write_text(path, c"struct R:\n\tint a\n\tint b\nR* f(int n): return (new R(n, 2))\nR* g(): return (new R(b: 42))\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 2\n")
		process_result_free(ast)
		char** args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, path)
		ast = ast_test_run(args, 0)
		assert_equal(0, ast.status)
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"struct R:\n\tint a\n\tint b\nint main(): return (cast(int, new R(1)))\n")
	ast_test_diagnostics(c"struct R:\n\tint a\nint main(): return (cast(int, new R(1, 2)))\n")
	ast_test_diagnostics(c"struct R:\n\tint a\nint main(): return (cast(int, new R(missing: 1)))\n")
	ast_test_diagnostics(c"struct R:\n\tint a\n\tint b\nint main(): return (cast(int, new R(a: 1, 2)))\n")
	ast_test_diagnostics(c"struct R:\n\tint a\n\tint b\nint main(): return (cast(int, new R(1, b: 2)))\n")
	ast_test_diagnostics(c"struct R:\n\tint a\nint main(): return (cast(int, new R(c\"bad\")))\n")
	ast_test_diagnostics(c"struct R:\n\tint[2] a\nint main(): return (cast(int, new R(a: 1)))\n")
	ast_test_diagnostics(c"struct R:\n\tint a\nint main(): return (cast(int, new R(0xffffffff)))\n")


void test_ast_sized_array_allocation_hits_and_diagnostics():
	char* path = ast_test_path(c"_array_allocation.w")
	assert1(file_write_text(path, c"int[] f(int n): return (new int[n + 1])\nchar[] g(): return (new char[0])\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		assert_contains(ast.stderr_text, c"AST expressions: 2\n")
		process_result_free(ast)
		char** args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, path)
		ast = ast_test_run(args, 0)
		assert_equal(0, ast.status)
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_diagnostics(c"int main(): return (cast(int, new void[3]))\n")
	ast_test_diagnostics(c"int main(): return (cast(int, new int[0xffffffff]))\n")
	ast_test_diagnostics(c"int main(): return (cast(int, new int[2 + ]))\n")
	ast_test_diagnostics(c"int main(): return (cast(int, new int[3))\n")


void test_ast_scalar_map_expression_hits_and_diagnostics():
	char* path = ast_test_path(c"_map.w")
	assert1(file_write_text(path, c"int f(map[int, int] m): return (m[1])\nint g(map[int, int] m): return (m[1] = 42)\nint h(map[int, int] m): return (m[1] += 2)\nint main(): return 0\n"))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 1)
		assert_equal(0, ast.status)
		# Lint events are retained: both stores and the read use the AST.
		assert_contains(ast.stderr_text, c"AST expressions: 3\n")
		process_result_free(ast)
		char** args = strv_new(6)
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, path)
		ast = ast_test_run(args, 0)
		assert_equal(0, ast.status)
		process_result_free(ast)
	unlink(path)
	free(path)
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m[c\"bad\"] = 42)\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m[1] = c\"bad\")\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(map[int, string] m): return (m[1] += s\"bad\")\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(map[int, int] m, string s): return (m[s.length] = 42)\nint main(): return 0\n")
	ast_test_diagnostics(c"int f(map[int, int] m): return (m[1 + ])\nint main(): return 0\n")


void test_ast_return_statement_coverage_and_diagnostics():
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		for source in range(2):
			char** args = strv_new(7)
			strv_set(args, 0, compiler)
			strv_set(args, 1, c"check")
			strv_set(args, 2, c"--quiet")
			strv_set(args, 3, c"x64")
			strv_set(args, 4, c"--ast-required")
			strv_set(args, 5, c"--stats")
			char* path = c"tests/ast_return_statement_fixture.w"
			if (source): path = c"w.w"
			strv_set(args, 6, path)
			process_result* result = ast_test_run(args, 0)
			assert_equal(0, result.status)
			assert_contains(result.stderr_text, c"Streaming expression roots: 0\n")
			process_result_free(result)
	ast_test_diagnostics(c"int main(): return c\"bad\"\n")
	ast_test_diagnostics(c"int main(): return (1 + )\n")
	ast_test_diagnostics(c"int main(): return :\n")
	ast_test_diagnostics(c"int main() { return }\n")
	ast_test_diagnostics(c"int main(): return 7")
	ast_test_diagnostics(c"void f(): return\nint main(): return 0\n")


void test_ast_generic_required_and_diagnostics():
	for host in range(2):
		char** args = strv_new(6)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, c"tests/ast_migration_generic_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_diagnostics(c"T ident[T](T n): return n\nint main(): return (ident[int](c\"bad\"))\n")
	ast_test_diagnostics(c"T ident[T](T n): return n\nint main(): return (ident[int]())\n")
	ast_test_diagnostics(c"T ident[T](T n): return n\nint main(): return (ident[int, int](1))\n")
	ast_test_diagnostics(c"T ident[T](T n): return n\nint main(): return (ident[missing](1))\n")
	ast_test_diagnostics(c"T ident[T](T n): return n\nint main(): return (ident[int](1) + ident[int](c\"bad\"))\n")


void test_ast_template_required_and_diagnostics():
	for host in range(2):
		char** args = strv_new(6)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, c"tests/ast_formatted_template_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_diagnostics(c"int main(): return (f\"{1:q}\".length)\n")
	ast_test_diagnostics(c"int main(): return (f\"{1:.2}\".length)\n")
	ast_test_diagnostics(c"int main(): return (f\"{s\"text\":04}\".length)\n")
	ast_test_diagnostics(c"int main(): return (f\"{1:4097}\".length)\n")
	ast_test_diagnostics(c"int main(): return (f\"{1.5:.61}\".length)\n")
	ast_test_diagnostics(c"int main(): return (f\"bad }\".length)\n")
	ast_test_diagnostics(c"int main(): return (f\"{1 + }\".length)\n")
	ast_test_diagnostics(c"int main(): return (f\"{1\".length)\n")
	ast_test_diagnostics(c"int main(): return (f\"\\uD800\".length)\n")
	ast_test_diagnostics(c"int main():\n\tint* p = 0\n\treturn (f\"{p}\".length)\n")


void test_ast_map_get_required_and_diagnostics():
	for host in range(2):
		char** args = strv_new(6)
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		strv_set(args, 0, compiler)
		strv_set(args, 1, c"check")
		strv_set(args, 2, c"--quiet")
		strv_set(args, 3, c"x64")
		strv_set(args, 4, c"--ast-required")
		strv_set(args, 5, c"tests/ast_map_get_fixture.w")
		process_result* result = ast_test_run(args, 0)
		assert_equal(0, result.status)
		process_result_free(result)
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m.get(c\"bad\"))\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m.get(1, c\"bad\"))\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m.get())\nint main(): return 0\n")
	ast_test_store_diagnostics(c"int f(map[int, int] m): return (m.get(1, 2, 3))\nint main(): return 0\n")


void test_ast_integrated_statement_and_expression_coverage():
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		for width in range(2):
			for source in range(2):
				char** args = strv_new(8)
				int i = 0
				i = ast_test_arg(args, i, compiler)
				i = ast_test_arg(args, i, c"check")
				i = ast_test_arg(args, i, c"--quiet")
				if (width): i = ast_test_arg(args, i, c"x64")
				i = ast_test_arg(args, i, c"--ast-required")
				i = ast_test_arg(args, i, c"--stats")
				char* path = c"tests/ast_statement_expression_fixture.w"
				if (source): path = c"tests/ast_integration_expression_fixture.w"
				i = ast_test_arg(args, i, path)
				process_result* result = ast_test_run(args, 0)
				assert_equal(0, result.status)
				assert_contains(result.stderr_text, c"Streaming expression roots: 0\n")
				assert_contains(result.stderr_text, c"AST expression statements: ")
				assert_substring(result.stderr_text, c"AST expression statements: 0\n", 0)
				process_result_free(result)


void test_ast_control_headers_and_collections_are_required():
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		for width in range(2):
			for source in range(6):
				if (source == 3 && width == 0): continue
				char* path = c"tests/ast_control_header_fixture.w"
				if (source == 1): path = c"tests/ast_collection_snapshot_fixture.w"
				if (source == 2): path = c"tests/ast_list_slice_expression_fixture.w"
				if (source == 3): path = c"tests/ast_collection_snapshot_x64_fixture.w"
				if (source == 4): path = c"tests/ast_map_integration_expression_fixture.w"
				if (source == 5): path = c"tests/ast_first_use_container_fixture.w"
				char** args = strv_new(8)
				int i = 0
				i = ast_test_arg(args, i, compiler)
				i = ast_test_arg(args, i, c"check")
				i = ast_test_arg(args, i, c"--quiet")
				if (width): i = ast_test_arg(args, i, c"x64")
				i = ast_test_arg(args, i, c"--ast-required")
				i = ast_test_arg(args, i, c"--stats")
				i = ast_test_arg(args, i, path)
				process_result* result = ast_test_run(args, 0)
				assert_equal(0, result.status)
				assert_contains(result.stderr_text, c"Streaming expression roots: 0\n")
				if (source == 0):
					assert_contains(result.stderr_text, c"AST if regions: ")
					assert_substring(result.stderr_text, c"AST if regions: 0\n", 0)
					assert_contains(result.stderr_text, c"AST while loops: ")
					assert_substring(result.stderr_text, c"AST while loops: 0\n", 0)
				process_result_free(result)
	ast_test_store_diagnostics(c"int main():\n\tint n = 0\n\tif (n = 2): return n\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tint n = 0\n\twhile (n = 2): return n\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tif (1 + ): return 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\twhile (missing): pass\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tif 0: return 1\n\telif (missing): return 2\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tif (4294967296): return 1\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tstring s = s\"abc\"\n\twhile (s.length = 0): pass\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\twhile (1 + )")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] counts = new map[int, int]\n\treturn counts.add()\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] counts = new map[int, int]\n\treturn counts.add(1, 2, 3)\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] counts = new map[int, int]\n\treturn counts.add(c\"bad\", 2)\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] counts = new map[int, int]\n\treturn counts.add(1, missing)\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, string] counts = new map[int, string]\n\tcounts.add(1)\n\treturn 0\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] counts = new map[int, int]\n\tlist[int] keys = counts.keys(1)\n\treturn keys.length\n")
	ast_test_store_diagnostics(c"int main():\n\tmap[int, int] counts = new map[int, int]\n\tlist[int] values = counts.values(1)\n\treturn values.length\n")


# Each REPL process owns /tmp/w_repl_<pid>; compare every diagnostic byte
# except that process-specific directory component. Entry indices, source
# coordinates, source text, caret placement and prompts remain significant.
char* ast_test_repl_diagnostic_text(char* text):
	string_builder* normalized = string_new()
	int i = 0
	while (text[i] != 0):
		if (starts_with(text + i, c"/tmp/w_repl_")):
			int digits = i + strlen(c"/tmp/w_repl_")
			int end = digits
			while (text[end] >= '0' && text[end] <= '9'): end = end + 1
			if (end > digits && text[end] == '/'):
				string_append(normalized, c"/tmp/w_repl_<pid>")
				i = end
		string_append_char(normalized, text[i])
		i = i + 1
	char* result = strclone(normalized.data)
	string_free(normalized)
	return result


void test_ast_control_header_repl_recovery():
	char* script = c"int header(int n) { if (n < 0) { return -1; } while (n > 2) { n -= 1; } return n; }\nheader(9)\nheader(-2)\nint header(int n): if (n + ): return n\nheader(9)\nint header(int n) { while (n > 0) { n -= 1; } return n; }\nheader(9)\n7427\n:quit\n"
	for host in range(2):
		char* repl = c"bin/ast_repl"
		if (host): repl = c"bin/ast_repl64"
		process_result* old = ast_test_repl(repl, 0, script)
		char* old_diagnostics = ast_test_repl_diagnostic_text(old.stderr_text)
		assert_strings_equal(c"2\n-1\n2\n0\n7427\n", old.stdout_text)
		assert_contains(old_diagnostics, c"entry_3.w:1:28")
		for enabled in range(1, 4):
			process_result* ast = ast_test_repl(repl, enabled, script)
			assert_equal(0, ast.status)
			assert_equal(old.status, ast.status)
			assert_strings_equal(old.stdout_text, ast.stdout_text)
			char* ast_diagnostics = ast_test_repl_diagnostic_text(ast.stderr_text)
			assert_strings_equal(old_diagnostics, ast_diagnostics)
			assert_contains(ast.stdout_text, c"7427")
			free(ast_diagnostics)
			process_result_free(ast)
		free(old_diagnostics)
		process_result_free(old)


void test_ast_first_use_container_repl_recovery():
	char* script = c"struct AstFresh:\n\tint value\n\n(list[AstFresh]{AstFresh(21)}.length + missing)\nitems := list[AstFresh]{AstFresh(42)}\nitems[0].value\n(list[list[AstFresh]]{list[AstFresh]{AstFresh(18446744073709551616)}}.length)\nnested := list[list[AstFresh]]{items}\nnested[0][0].value\nsizeof(list[AstFresh]**)\n7427\n:quit\n"
	for host in range(2):
		char* repl = c"bin/ast_repl"
		if (host): repl = c"bin/ast_repl64"
		process_result* old = ast_test_repl(repl, 0, script)
		char* old_diagnostics = ast_test_repl_diagnostic_text(old.stderr_text)
		if (host): assert_strings_equal(c"42\n42\n8\n7427\n", old.stdout_text)
		else: assert_strings_equal(c"42\n42\n4\n7427\n", old.stdout_text)
		assert_contains(old_diagnostics, c"Cannot find symbol: 'missing'")
		for enabled in range(1, 4):
			process_result* ast = ast_test_repl(repl, enabled, script)
			assert_equal(0, ast.status)
			assert_equal(old.status, ast.status)
			assert_strings_equal(old.stdout_text, ast.stdout_text)
			char* ast_diagnostics = ast_test_repl_diagnostic_text(ast.stderr_text)
			assert_strings_equal(old_diagnostics, ast_diagnostics)
			free(ast_diagnostics)
			process_result_free(ast)
		free(old_diagnostics)
		process_result_free(old)


# wbuild: binary=ast_expression_test tag=tests dep=build_x64 dep=wdbg dep=wdbg_x64 data=tests/extern_data_test.w data=tests/float_abi_test.w data=tests/extern_alias_test.w data=tests/wasm_extern_test.w data=tests/script_fixture.w data=tests/ast_global_fixture.w data=tests/ast_gpu_statement_fixture.w data=tests/ast_deferred_fixture.w data=tests/ast_scope_fixture.w data=tests/for_test.w data=tests/for_container_test.w data=tests/switch_test.w data=tests/ast_guard_fixture.w data=tests/ast_declaration_fixture.w data=tests/infer_test.w data=tests/const_initializer_test.w data=tests/ast_raw_statement_fixture.w data=tests/goto_test.w data=tests/ast_expression_statement_fixture.w data=tests/ast_value_statement_fixture.w data=tests/ast_simple_statement_fixture.w data=tests/ast_expression_fixture.w data=tests/ast_typed_expression_fixture.w data=tests/ast_scalar_expression_fixture.w data=tests/ast_logic_expression_fixture.w data=tests/ast_remaining_expression_fixture.w data=tests/ast_mutation_expression_fixture.w data=tests/ast_text_expression_fixture.w data=tests/ast_print_expression_fixture.w data=tests/ast_buffer_expression_fixture.w data=tests/ast_comment_expression_fixture.w data=tests/ast_list_expression_fixture.w data=tests/ast_pointer_type_expression_fixture.w data=tests/ast_callback_expression_fixture.w data=tests/ast_default_expression_fixture.w data=tests/ast_allocation_expression_fixture.w data=tests/ast_multiline_expression_fixture.w data=tests/ast_metadata_expression_fixture.w data=tests/ast_record_expression_fixture.w data=tests/ast_map_expression_fixture.w data=tests/ast_parallel_expression_fixture.w data=tests/ast_increment_expression_fixture.w data=tests/ast_wide_call_expression_fixture.w data=tests/ast_template_expression_fixture.w data=tests/ast_generic_expression_fixture.w data=tests/ast_buffer_value_expression_fixture.w data=tests/ast_slice_expression_fixture.w data=tests/ast_container_literal_expression_fixture.w data=tests/ast_constructor_expression_fixture.w data=tests/ast_new_array_expression_fixture.w data=tests/ast_list_slice_expression_fixture.w data=tests/ast_list_method_expression_fixture.w data=tests/ast_void_call_expression_fixture.w data=tests/ast_composite_type_expression_fixture.w data=tests/ast_integer_intrinsic_expression_fixture.w data=tests/ast_map_method_expression_fixture.w data=tests/ast_generator_call_expression_fixture.w data=tests/ast_list_callback_expression_fixture.w data=tests/ast_map_default_expression_fixture.w data=tests/ast_inferred_generic_expression_fixture.w data=tests/ast_variadic_expression_fixture.w data=tests/varargs_test.w data=tests/ast_atomic_expression_fixture.w data=tests/atomic_host_test.w data=tests/ast_generic_type_expression_fixture.w data=tests/ast_method_expression_fixture.w data=tests/ast_operator_expression_fixture.w data=tests/operator_overload_test.w data=tests/ast_var_expression_fixture.w data=tests/dynamic_var_test.w data=tests/c_import_bitfield_fixture.w data=tests/x64_c_import_bitfield_test.w data=tests/c_import_bitfield_fixture.h data=tests/ast_prelude_expression_fixture.w data=tests/ast_prelude_input_fixture.w data=tests/prelude_test.w data=tests/ast_json_expression_fixture.w data=tests/json_codec_test.w data=tests/ast_protobuf_expression_fixture.w data=tests/protobuf_message_test.w data=tests/ast_utf8_expression_fixture.w data=tests/utf8_identifier_test.w data=tests/ast_large_literal_expression_fixture.w data=graphics/ui/font_data.w data=tests/ast_ndarray_expression_fixture.w data=tests/ndarray_index_test.w data=tests/ast_buffer_flow_expression_fixture.w data=tests/array_decay_test.w data=tests/matrix_linalg_test.w data=tests/ast_template_format_expression_fixture.w data=tests/template_format_test.w data=tests/template_format_float64_test.w data=tests/ast_qualified_expression_fixture.w data=tests/import_alias_type_test.w data=tests/import_test.w data=tests/ast_device_expression_fixture.w data=tests/gpu_ptx_emit.w data=tests/cuda_gpu.w data=tests/ast_gpu_qualified_expression_fixture.w data=tests/gpu_qualifier_ptx.w data=tests/gpu_qualifier_gpu.w data=tests/expression_nesting_clean_fixture.w data=tests/ternary_nesting_clean_fixture.w data=tests/gpu_qualifier_ok_fixture.w data=tests/ast_list_it_expression_fixture.w data=tests/list_it_test.w data=tests/golf_it_ints_test.w data=tests/golf_transpose_test.w data=tests/ast_bare_callback_expression_fixture.w data=libs/standard/distributed/raft_sweep_test.w data=tests/generics_test.w data=tests/ast_propagation_expression_fixture.w data=tests/ast_continuation_expression_fixture.w data=tests/lint_warn_fixture.w data=tests/lint_clean_fixture.w data=tests/bool_bitwise_warning_fixture.w data=tests/bool_bitwise_chain_fixture.w data=tests/bool_ops_warn_fixture.w data=structures/hash_table_test.w data=tests/default_args_missing_warning_fixture.w data=tests/list_builtin_warning_fixture.w data=tests/map_default_warning_fixture.w data=tests/warning_fixture.w data=tests/type_system_warning_fixture.w data=tests/ndarray_index_warning_fixture.w data=tests/atomic_host_operand_error_fixture.w data=tests/limb_builtin_warning_fixture.w data=tests/array_cast_warning_fixture.w data=tests/cross_line_call_warning_fixture.w data=tests/shell_commands_test.w data=tests/warning_clean_fixture.w data=tests/result_propagate_test.w data=tests/generator_return_free_test.w data=tests/feature_combo_test.w data=tests/ast_first_use_container_fixture.w data=tests/ast_map_integration_expression_fixture.w data=tests/ast_collection_snapshot_fixture.w data=tests/ast_control_header_fixture.w data=tests/ast_collection_snapshot_x64_fixture.w data=tests/ast_statement_expression_fixture.w data=tests/ast_integration_expression_fixture.w data=tests/ast_scalar_map_expression_fixture.w data=tests/ast_array_allocation_fixture.w data=tests/ast_migration_constructor_fixture.w data=tests/ast_map_default_fixture.w data=tests/ast_map_get_fixture.w data=tests/ast_formatted_template_fixture.w data=tests/ast_migration_generic_fixture.w data=tests/ast_return_statement_fixture.w data=tests/unsigned_compare_test.w data=tests/x64_unsigned_compare_test.w
# wbuild: step="bin/wv2 repl.w -o bin/ast_repl"
# wbuild: step="bin/wv2 x64 repl.w -o bin/ast_repl64"
# wbuild: step="bin/ast_expression_test"
# wbuild: target=ast_expression_verify tag=tests dep=build dep=build_x64
# wbuild: step="bin/wv2 --streaming --ast-expressions --strict w.w -o bin/ast_wv3"
# wbuild: step="cmp bin/wv3 bin/ast_wv3"
# wbuild: step="bin/ast_wv3 --streaming --ast-expressions --strict w.w -o bin/ast_wv4"
# wbuild: step="cmp bin/ast_wv3 bin/ast_wv4"
# wbuild: step="bin/wv2_64 x64 --streaming --ast-expressions --strict w.w -o bin/ast_wv3_64"
# wbuild: step="cmp bin/wv3_64 bin/ast_wv3_64"
# wbuild: step="bin/ast_wv3_64 x64 --streaming --ast-expressions --strict w.w -o bin/ast_wv4_64"
# wbuild: step="cmp bin/ast_wv3_64 bin/ast_wv4_64"
# wbuild: step="bin/wv2 --streaming --strict w.w -o bin/streaming_wv3"
# wbuild: step="cmp bin/wv3 bin/streaming_wv3"
# wbuild: step="bin/streaming_wv3 --streaming --strict w.w -o bin/streaming_wv4"
# wbuild: step="cmp bin/streaming_wv3 bin/streaming_wv4"
# wbuild: step="bin/wv2_64 x64 --streaming --strict w.w -o bin/streaming_wv3_64"
# wbuild: step="cmp bin/wv3_64 bin/streaming_wv3_64"
# wbuild: step="bin/streaming_wv3_64 x64 --streaming --strict w.w -o bin/streaming_wv4_64"
# wbuild: step="cmp bin/streaming_wv3_64 bin/streaming_wv4_64"

# wbuild: target=ast_required_expression_verify tag=tests dep=build dep=build_x64
# wbuild: step="bin/wv2 --ast-required --strict w.w -o bin/ast_required_wv3"
# wbuild: step="cmp bin/wv3 bin/ast_required_wv3"
# wbuild: step="bin/ast_required_wv3 --ast-required --strict w.w -o bin/ast_required_wv4"
# wbuild: step="cmp bin/ast_required_wv3 bin/ast_required_wv4"
# wbuild: step="bin/wv2_64 x64 --ast-required --strict w.w -o bin/ast_required_wv3_64"
# wbuild: step="cmp bin/wv3_64 bin/ast_required_wv3_64"
# wbuild: step="bin/ast_required_wv3_64 x64 --ast-required --strict w.w -o bin/ast_required_wv4_64"
# wbuild: step="cmp bin/ast_required_wv3_64 bin/ast_required_wv4_64"
# wbuild: step="bin/wv2 --ast-required --ast-emit-retained --strict w.w -o bin/ast_emit_retained_wv3"
# wbuild: step="cmp bin/wv3 bin/ast_emit_retained_wv3"
# wbuild: step="bin/ast_emit_retained_wv3 --ast-required --ast-emit-retained --strict w.w -o bin/ast_emit_retained_wv4"
# wbuild: step="cmp bin/ast_emit_retained_wv3 bin/ast_emit_retained_wv4"
# wbuild: step="bin/wv2_64 x64 --ast-required --ast-emit-retained --strict w.w -o bin/ast_emit_retained_wv3_64"
# wbuild: step="cmp bin/wv3_64 bin/ast_emit_retained_wv3_64"
# wbuild: step="bin/ast_emit_retained_wv3_64 x64 --ast-required --ast-emit-retained --strict w.w -o bin/ast_emit_retained_wv4_64"
# wbuild: step="cmp bin/ast_emit_retained_wv3_64 bin/ast_emit_retained_wv4_64"
