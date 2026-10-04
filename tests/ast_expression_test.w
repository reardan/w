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


void test_ast_expression_images_and_host_widths():
	ast_test_image(c"bin/wv2", c"x86", 1)
	ast_test_image(c"bin/wv2", c"x64", 1)
	ast_test_image(c"bin/wv2_64", c"x86", 1)
	ast_test_image(c"bin/wv2_64", c"x64", 1)
	ast_test_image(c"bin/wv2", c"arm64", 0)
	ast_test_image(c"bin/wv2", c"arm64_darwin", 0)
	ast_test_image(c"bin/wv2", c"win64", 0)
	ast_test_image(c"bin/wv2", c"wasm", 0)


void ast_test_diagnostics(char* source):
	char* path = ast_test_path(c".w")
	assert1(file_write_text(path, source))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		process_result* old = ast_test_compile(compiler, c"x64", path, 0, 0, 1, 0)
		for enabled in range(1, 3):
			process_result* ast = ast_test_compile(compiler, c"x64", path, 0, enabled, 1, 0)
			assert_equal(old.status, ast.status)
			assert_strings_equal(old.stdout_text, ast.stdout_text)
			assert_strings_equal(old.stderr_text, ast.stderr_text)
			process_result_free(ast)
		process_result_free(old)
	unlink(path)
	free(path)


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
	assert_contains(audit.stderr_text, c"\"ast_fallback\": true")
	assert_contains(audit.stderr_text, c"AST expression roots: ")
	assert_contains(audit.stderr_text, c"Streaming expression roots: ")
	process_result_free(audit)
	args = strv_new(5)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--quiet")
	strv_set(args, 3, c"--ast-required")
	strv_set(args, 4, path)
	process_result* required = ast_test_run(args, 0)
	assert_equal(1, required.status)
	assert_contains(required.stderr_text, c"AST-required compilation encountered an unsupported expression")
	# Even this trivial root includes the implicit runtime. Requiring
	# AST must reject its unsupported code, not silently skip imports.
	assert_contains(required.stderr_text, c"code_generator/integer.w")
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
	char* script = c"(6 * 7)\n(4294967296 + 1)\n(1 + )\nint keep = (5 * 9)\nkeep + (2 * 3)\n(keep) = 23\n(keep + 7)\nint keep = 60\n(keep + 3)\nint old(): return (keep + 4)\n(keep + missing)\n(old())\nint callee(int n): return n + 1\nint caller(int n): return (callee(n) * 2)\n(caller(20))\nint callee(int n): return n + 3\n(caller(20))\n(1.5 + 2.5)\n(1e+ + 2)\n(caller(20))\nint* nil = 0\n(nil && nil[0])\n(!nil || *nil)\n(2 < 3 && caller(20) == 46)\n(false && missing)\n(caller(20) >= 46)\nbool yes = true\n(yes)\n(!yes)\n:reset\n(8 * 9)\n:quit\n"
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


# wbuild: binary=ast_expression_test tag=tests dep=build_x64 dep=wdbg dep=wdbg_x64 data=tests/ast_expression_fixture.w data=tests/ast_typed_expression_fixture.w data=tests/ast_scalar_expression_fixture.w data=tests/ast_logic_expression_fixture.w data=tests/ast_remaining_expression_fixture.w data=tests/ast_mutation_expression_fixture.w data=tests/ast_text_expression_fixture.w data=tests/ast_print_expression_fixture.w data=tests/ast_buffer_expression_fixture.w data=tests/ast_comment_expression_fixture.w data=tests/operator_overload_test.w
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
# wbuild: step="bin/wv2 --ast-full-expressions --strict w.w -o bin/ast_full_wv3"
# wbuild: step="cmp bin/wv3 bin/ast_full_wv3"
# wbuild: step="bin/ast_full_wv3 --ast-full-expressions --strict w.w -o bin/ast_full_wv4"
# wbuild: step="cmp bin/ast_full_wv3 bin/ast_full_wv4"
# wbuild: step="bin/wv2_64 x64 --ast-full-expressions --strict w.w -o bin/ast_full_wv3_64"
# wbuild: step="cmp bin/wv3_64 bin/ast_full_wv3_64"
# wbuild: step="bin/ast_full_wv3_64 x64 --ast-full-expressions --strict w.w -o bin/ast_full_wv4_64"
# wbuild: step="cmp bin/ast_full_wv3_64 bin/ast_full_wv4_64"
