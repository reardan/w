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
	char** args = strv_new(12)
	int i = 0
	i = ast_test_arg(args, i, compiler)
	if (checking):
		i = ast_test_arg(args, i, c"check")
		i = ast_test_arg(args, i, c"--json")
		i = ast_test_arg(args, i, c"--lint")
		i = ast_test_arg(args, i, c"--imports")
	if (strcmp(arch, c"x86") != 0): i = ast_test_arg(args, i, arch)
	i = ast_test_arg(args, i, c"--quiet")
	if (enabled == 1): i = ast_test_arg(args, i, c"--ast-expressions")
	if (enabled == 2): i = ast_test_arg(args, i, c"--ast-full-expressions")
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
		process_result* ast = ast_test_compile(compiler, arch, source, b, enabled, 0, 0)
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


void test_ast_expression_images_and_host_widths():
	ast_test_image(c"bin/wv2", c"x86", 1)
	ast_test_image(c"bin/wv2", c"x64", 1)
	ast_test_image(c"bin/wv2_64", c"x86", 1)
	ast_test_image(c"bin/wv2_64", c"x64", 1)
	ast_test_image(c"bin/wv2", c"arm64", 0)
	ast_test_image(c"bin/wv2", c"arm64_darwin", 0)
	ast_test_image(c"bin/wv2", c"win64", 0)
	ast_test_image(c"bin/wv2", c"wasm", 0)


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
	# Lint-bearing stores deliberately use streaming diagnostics. Also
	# compile normally to exercise AST store validation itself.
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
	for i in range(150): string_append(source, c"1 + ")
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
	# The implicit runtime now fits the AST subset. An explicit unsupported
	# template format spec still proves that required mode cannot fall back.
	assert1(file_write_text(path, c"int main():\n\tstring text = f\"{1:04d}\"\n\treturn text.length\n"))
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
	char** args = strv_new(6)
	int i = 0
	i = ast_test_arg(args, i, c"bin/wv2")
	i = ast_test_arg(args, i, command)
	if (strcmp(command, c"defhash") != 0): i = ast_test_arg(args, i, c"--json")
	i = ast_test_arg(args, i, c"--quiet")
	if (enabled == 1): i = ast_test_arg(args, i, c"--ast-expressions")
	if (enabled == 2): i = ast_test_arg(args, i, c"--ast-full-expressions")
	strv_set(args, i, source)
	return ast_test_run(args, 0)


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
		assert_contains(ast.stderr_text, c"AST expressions: 5\n")
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
	char** args = strv_new(2)
	strv_set(args, 0, repl)
	if (enabled == 1): strv_set(args, 1, c"--ast-expressions")
	if (enabled == 2): strv_set(args, 1, c"--ast-full-expressions")
	return ast_test_run(args, script)


void test_ast_expression_repl_recovery():
	char* script = c"(6 * 7)\n(4294967296 + 1)\n(1 + )\nint keep = (5 * 9)\nkeep + (2 * 3)\n(keep) = 23\n(keep + 7)\nint keep = 60\n(keep + 3)\nint old(): return (keep + 4)\n(keep + missing)\n(old())\nint callee(int n): return n + 1\nint caller(int n): return (callee(n) * 2)\n(caller(20))\nint callee(int n): return n + 3\n(caller(20))\n(1.5 + 2.5)\n(1e+ + 2)\n(caller(20))\nint* nil = 0\n(nil && nil[0])\n(!nil || *nil)\n(2 < 3 && caller(20) == 46)\n(false && missing)\n(caller(20) >= 46)\nbool yes = true\n(yes)\n(!yes)\nstruct AstPointer: int x\n(cast(AstPointer**, 0) + missing)\n(cast(AstPointer**, 0) == 0)\n(cast(AstPointer***, 0) + )\n(cast(AstPointer***, 0) == 0)\n:reset\n(8 * 9)\n:quit\n"
	for host in range(2):
		char* repl = c"bin/ast_repl"
		if (host): repl = c"bin/ast_repl64"
		process_result* old = ast_test_repl(repl, 0, script)
		for enabled in range(1, 3):
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
		for enabled in range(3):
			char** args = strv_new(3)
			char* dbg_path = c"bin/wdbg"
			if (host): dbg_path = c"bin/wdbg64"
			strv_set(args, 0, dbg_path)
			strv_set(args, 1, path)
			if (enabled == 1): strv_set(args, 2, c"--ast-expressions")
			if (enabled == 2): strv_set(args, 2, c"--ast-full-expressions")
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


# wbuild: binary=ast_expression_test tag=tests dep=build_x64 dep=wdbg dep=wdbg_x64 data=tests/ast_expression_fixture.w data=tests/ast_typed_expression_fixture.w data=tests/ast_scalar_expression_fixture.w data=tests/ast_logic_expression_fixture.w data=tests/ast_remaining_expression_fixture.w data=tests/ast_mutation_expression_fixture.w data=tests/ast_text_expression_fixture.w data=tests/ast_print_expression_fixture.w data=tests/ast_buffer_expression_fixture.w data=tests/ast_comment_expression_fixture.w data=tests/ast_list_expression_fixture.w data=tests/ast_pointer_type_expression_fixture.w data=tests/ast_callback_expression_fixture.w data=tests/ast_default_expression_fixture.w data=tests/ast_allocation_expression_fixture.w data=tests/ast_multiline_expression_fixture.w data=tests/ast_metadata_expression_fixture.w data=tests/ast_record_expression_fixture.w data=tests/ast_map_expression_fixture.w data=tests/ast_parallel_expression_fixture.w data=tests/ast_increment_expression_fixture.w data=tests/ast_wide_call_expression_fixture.w data=tests/ast_template_expression_fixture.w data=tests/ast_generic_expression_fixture.w data=tests/ast_buffer_value_expression_fixture.w data=tests/ast_slice_expression_fixture.w data=tests/ast_container_literal_expression_fixture.w data=tests/operator_overload_test.w
# wbuild: step="bin/wv2 repl.w -o bin/ast_repl"
# wbuild: step="bin/wv2 x64 repl.w -o bin/ast_repl64"
# wbuild: step="bin/ast_expression_test"
# wbuild: target=ast_expression_verify tag=tests dep=build dep=build_x64
# wbuild: step="bin/wv2 --ast-expressions --strict w.w -o bin/ast_wv3"
# wbuild: step="cmp bin/wv3 bin/ast_wv3"
# wbuild: step="bin/ast_wv3 --ast-expressions --strict w.w -o bin/ast_wv4"
# wbuild: step="cmp bin/ast_wv3 bin/ast_wv4"
# wbuild: step="bin/wv2_64 x64 --ast-expressions --strict w.w -o bin/ast_wv3_64"
# wbuild: step="cmp bin/wv3_64 bin/ast_wv3_64"
# wbuild: step="bin/ast_wv3_64 x64 --ast-expressions --strict w.w -o bin/ast_wv4_64"
# wbuild: step="cmp bin/ast_wv3_64 bin/ast_wv4_64"
# wbuild: step="bin/wv2 --ast-required --strict w.w -o bin/ast_full_wv3"
# wbuild: step="cmp bin/wv3 bin/ast_full_wv3"
# wbuild: step="bin/ast_full_wv3 --ast-required --strict w.w -o bin/ast_full_wv4"
# wbuild: step="cmp bin/ast_full_wv3 bin/ast_full_wv4"
# wbuild: step="bin/wv2_64 x64 --ast-required --strict w.w -o bin/ast_full_wv3_64"
# wbuild: step="cmp bin/wv3_64 bin/ast_full_wv3_64"
# wbuild: step="bin/ast_full_wv3_64 x64 --ast-required --strict w.w -o bin/ast_full_wv4_64"
# wbuild: step="cmp bin/ast_full_wv3_64 bin/ast_full_wv4_64"
