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
	if (enabled): i = ast_test_arg(args, i, c"--ast-expressions")
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
	process_result* ast = ast_test_compile(compiler, arch, source, b, 1, 0, 0)
	assert_equal(0, old.status)
	assert_equal(0, ast.status)
	assert_strings_equal(old.stdout_text, ast.stdout_text)
	assert_strings_equal(old.stderr_text, ast.stderr_text)
	ast_test_same_file(a, b)
	process_result_free(old)
	process_result_free(ast)
	if (run):
		char** args = strv_new(1)
		strv_set(args, 0, b)
		ast = ast_test_run(args, 0)
		assert_equal(0, ast.status)
		process_result_free(ast)
	unlink(a)
	unlink(b)
	free(a)
	free(b)


void ast_test_image(char* compiler, char* arch, int run):
	ast_test_image_at(compiler, arch, c"tests/ast_expression_fixture.w", run)
	ast_test_image_at(compiler, arch, c"tests/ast_typed_expression_fixture.w", run)


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
		process_result* ast = ast_test_compile(compiler, c"x64", path, 0, 1, 1, 0)
		assert_equal(old.status, ast.status)
		assert_strings_equal(old.stdout_text, ast.stdout_text)
		assert_strings_equal(old.stderr_text, ast.stderr_text)
		process_result_free(old)
		process_result_free(ast)
	unlink(path)
	free(path)


void test_ast_expression_diagnostics_and_fallback():
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
	assert1(file_write_text(path, c"int main(): return (1.5 + 2.5)\n"))
	ast = ast_test_compile(c"bin/wv2", c"x86", path, 0, 1, 1, 1)
	assert_contains(ast.stderr_text, c"AST expressions: 0\n")
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


process_result* ast_test_query(char* command, int enabled):
	char** args = strv_new(6)
	int i = 0
	i = ast_test_arg(args, i, c"bin/wv2")
	i = ast_test_arg(args, i, command)
	if (strcmp(command, c"defhash") != 0): i = ast_test_arg(args, i, c"--json")
	i = ast_test_arg(args, i, c"--quiet")
	if (enabled): i = ast_test_arg(args, i, c"--ast-expressions")
	strv_set(args, i, c"tests/ast_expression_fixture.w")
	return ast_test_run(args, 0)


void test_ast_expression_analysis_queries():
	char*[3] commands
	commands[0] = c"symbols"
	commands[1] = c"deps"
	commands[2] = c"defhash"
	for i in range(3):
		process_result* old = ast_test_query(commands[i], 0)
		process_result* ast = ast_test_query(commands[i], 1)
		assert_equal(0, old.status)
		assert_equal(0, ast.status)
		assert_strings_equal(old.stdout_text, ast.stdout_text)
		assert_strings_equal(old.stderr_text, ast.stderr_text)
		process_result_free(old)
		process_result_free(ast)


process_result* ast_test_repl(char* repl, int enabled, char* script):
	char** args = strv_new(2)
	strv_set(args, 0, repl)
	if (enabled): strv_set(args, 1, c"--ast-expressions")
	return ast_test_run(args, script)


void test_ast_expression_repl_recovery():
	char* script = c"(6 * 7)\n(4294967296 + 1)\n(1 + )\nint keep = (5 * 9)\nkeep + (2 * 3)\n(keep) = 23\n(keep + 7)\nint keep = 60\n(keep + 3)\nint old(): return (keep + 4)\n(keep + missing)\n(old())\nbool yes = true\n(yes)\n(!yes)\n:reset\n(8 * 9)\n:quit\n"
	for host in range(2):
		char* repl = c"bin/ast_repl"
		if (host): repl = c"bin/ast_repl64"
		process_result* old = ast_test_repl(repl, 0, script)
		process_result* ast = ast_test_repl(repl, 1, script)
		assert_equal(0, ast.status)
		assert_equal(old.status, ast.status)
		assert_strings_equal(old.stdout_text, ast.stdout_text)
		assert_contains(ast.stdout_text, c"42")
		assert_contains(ast.stdout_text, c"51")
		assert_contains(ast.stdout_text, c"72")
		assert_contains(ast.stdout_text, c"30")
		assert_contains(ast.stdout_text, c"63")
		assert_contains(ast.stdout_text, c"64")
		assert_contains(ast.stderr_text, c"integer literal has more than 32 significant bits")
		process_result_free(old)
		process_result_free(ast)


void test_ast_expression_debugger_eval():
	char* path = ast_test_path(c".w")
	assert1(file_write_text(path, c"int main():\n\tint answer = (6 * 7)\n\tdebugger\n\treturn answer != 42\n"))
	for host in range(2):
		for enabled in range(2):
			char** args = strv_new(3)
			char* dbg_path = c"bin/wdbg"
			if (host): dbg_path = c"bin/wdbg64"
			strv_set(args, 0, dbg_path)
			strv_set(args, 1, path)
			if (enabled): strv_set(args, 2, c"--ast-expressions")
			process_result* result = ast_test_run(args, c"p answer\np (answer + 5)\np (answer + missing)\np (5 + 6 * 7)\np (4294967296 + 1)\np (6 * 7)\nc\n")
			assert_equal(0, result.status)
			assert_contains(result.stdout_text, c"answer = 42")
			assert_contains(result.stdout_text, c"wdbg> = 47")
			assert_contains(result.stdout_text, c"wdbg> = 42")
			assert_contains(result.stdout_text, c".w:3)")
			assert_contains(result.stderr_text, c"integer literal has more than 32 significant bits")
			process_result_free(result)
	unlink(path)
	free(path)


# wbuild: binary=ast_expression_test tag=tests dep=build_x64 dep=wdbg dep=wdbg_x64 data=tests/ast_expression_fixture.w data=tests/ast_typed_expression_fixture.w data=tests/operator_overload_test.w
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
