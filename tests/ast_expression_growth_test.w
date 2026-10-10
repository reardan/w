# wbuild: binary=ast_expression_growth_test tag=tests dep=build dep=build_x64
# wbuild: step="bin/ast_expression_growth_test"
import lib.testing
import lib.file
import lib.process


char* growth_path(char* suffix):
	string_builder* name = string_from(c"bin/ast_growth_test_")
	string_append_int(name, getpid())
	string_append(name, suffix)
	char* path = strclone(name.data)
	string_free(name)
	return path


process_result* growth_compile(char* compiler, char* arch, char* source, char* output, int mode):
	char** args = strv_new(10)
	strv_set(args, 0, compiler)
	strv_set(args, 1, arch)
	strv_set(args, 2, c"--quiet")
	strv_set(args, 3, c"--strict")
	if (mode == 0): strv_set(args, 4, c"--streaming")
	else: strv_set(args, 4, c"--ast-required")
	strv_set(args, 5, source)
	strv_set(args, 6, c"-o")
	strv_set(args, 7, output)
	if (mode == 2): strv_set(args, 8, c"--ast-retain")
	process_result* result = process_run(compiler, args, 0, 0, 30000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


void growth_compare(char* source, int semantic):
	char* path = growth_path(c".w")
	char* old_path = growth_path(c".streaming")
	char* new_path = growth_path(c".ast")
	assert1(file_write_text(path, source))
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = c"--quiet"
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		process_result* old = growth_compile(compiler, arch, path, old_path, 0)
		assert_equal(0, old.status)
		for mode in range(1, 2 + semantic):
			process_result* ast = growth_compile(compiler, arch, path, new_path, mode)
			assert_equal(0, ast.status)
			assert_strings_equal(old.stdout_text, ast.stdout_text)
			assert_strings_equal(old.stderr_text, ast.stderr_text)
			process_result_free(ast)
			int fd = open(old_path, 0, 0)
			int gd = open(new_path, 0, 0)
			assert1((fd >= 0) && (gd >= 0))
			int length = file_size(fd)
			assert_equal(length, file_size(gd))
			char* first = file_read_text(old_path)
			char* second = file_read_text(new_path)
			assert_bytes_equal(first, second, length)
			free(first)
			free(second)
			close(fd)
			close(gd)
			char** args = strv_new(1)
			strv_set(args, 0, new_path)
			process_result* run = process_run(new_path, args, 0, 0, 30000)
			assert1(run != 0)
			assert_equal(0, run.status)
			process_result_free(run)
			free(cast(void*, args))
		process_result_free(old)
	unlink(path)
	unlink(old_path)
	unlink(new_path)
	free(path)
	free(old_path)
	free(new_path)


void test_ast_growing_nodes_text_source_and_parallel_scratch():
	string_builder* source = string_from(c"char* text(): return c\"")
	for i in range(100000): string_append_char(source, 'a')
	string_append(source, c"\"\nint main():\n\tint x = 0\n\t")
	for i in range(2499): string_append(source, c"x, ")
	string_append(source, c"x = ")
	for i in range(2499): string_append(source, c"x + 1, ")
	string_append(source, c"x + 1\n\tif (x != 1): return 1\n\tif (text()[99999] != 'a'): return 2\n\treturn (")
	for i in range(12000): string_append(source, c"x + ")
	string_append(source, c"x) - 12001\n")
	growth_compare(source.data, 1)
	string_free(source)


void test_ast_flat_binary_chain_uses_a_growing_work_stack():
	# This is deliberately wider than the native call stack. Source
	# nesting remains one level, so the parser's depth guard cannot help.
	string_builder* source = string_from(c"int main(): return ")
	for i in range(300000): string_append(source, c"1 + ")
	string_append(source, c"1 - 300001\n")
	growth_compare(source.data, 0)
	string_free(source)


void test_ast_flat_postfix_receivers_preserve_side_effect_order():
	string_builder* source = string_from(c"struct GrowthLink:\n\tGrowthLink* next\n\tint visits\nint marked\nint mark():\n\tmarked = marked + 1\n\treturn marked\nGrowthLink* visit(GrowthLink* self, int expected):\n\tself.visits = self.visits + 1\n\tif (self.visits != expected): return 0\n\treturn self\nint main():\n\tGrowthLink link\n\tlink.next = &link\n\tlink.visits = 0\n\tGrowthLink* pointer = &link\n\treturn pointer")
	for i in range(12000): string_append(source, c".next.visit(mark())")
	string_append(source, c".visits - 12000\n")
	growth_compare(source.data, 0)
	string_free(source)
