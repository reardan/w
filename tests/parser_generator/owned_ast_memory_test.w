# wbuild: target=owned_ast_memory_test tag=tests dep=parser_generator_w_test
# wbuild: step="bin/wv2 tests/parser_generator/owned_ast_memory_test.w -o bin/owned_ast_memory_test"
# wbuild: step="bin/owned_ast_memory_test" expect_stdout="owned_ast_memory_test: OK"
# wbuild: target=owned_ast_memory_64_test tag=tests_x64 dep=parser_generator_w_test
# wbuild: step="bin/wv2 x64 tests/parser_generator/owned_ast_memory_test.w -o bin/owned_ast_memory_64_test"
# wbuild: step="bin/owned_ast_memory_64_test" expect_stdout="owned_ast_memory_test: OK"
# Fresh processes isolate the guard allocator's zero-leak assertion.
import lib.assert
import libs.extras.parser_generator.runtime
import bin.generated_w_parser


void owned_ast_parse(char* source, int valid):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = wlang_lex(source, c"owned.w", diagnostics)
	pg_token_stream_own_ast(stream)
	pg_ast_node* root = wlang_parse_program(stream, diagnostics)
	if (valid):
		assert1(root != 0)
		assert_equal(0, pg_diagnostics_count(diagnostics))
		assert_equal(wlang_ast_program, root.kind)
	else:
		assert1(root == 0 || pg_diagnostics_count(diagnostics) > 0)
	char* rebuilt = pg_token_stream_source(stream)
	assert_strings_equal(source, rebuilt)
	free(rebuilt)
	# Includes nodes abandoned during speculation and recovery, not just root.
	pg_token_stream_free(stream)
	pg_diagnostics_free(diagnostics)


int main():
	malloc_force_debug_mode()
	pg_diagnostics* retained_diagnostics = pg_diagnostics_new()
	pg_token_stream* retained = wlang_lex(c"int keep(): return 7\n", c"keep.w", retained_diagnostics)
	pg_token_stream_own_ast(retained)
	pg_ast_node* root = wlang_parse_program(retained, retained_diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(retained_diagnostics))
	for i in range(3):
		owned_ast_parse(c"int f(int x):\n\tif x: return 2 + 3 * 4\n\treturn 0\n", 1)
		owned_ast_parse(c"struct Pair:\n\tint x\nint f():\n\tPair p\n\tp.x = 7\n\treturn p.x\n", 1)
		owned_ast_parse(c"int f(\nint good(): return 1\n", 0)
		owned_ast_parse(c"int f(): return @\n", 0)
		owned_ast_parse(c"", 1)
	# Another stream's destruction must not invalidate this tree or its tokens.
	assert_equal(wlang_ast_program, root.kind)
	assert_strings_equal(c"int", pg_ast_first_token(root).text)
	pg_token_stream_free(retained)
	pg_diagnostics_free(retained_diagnostics)
	# Factored prefixes may be linked from multiple speculative parents.
	pg_token_stream* shared = pg_token_stream_new()
	pg_token_stream_own_ast(shared)
	pg_ast_node* left = pg_token_stream_ast_new(shared, 1, 0, c"left")
	pg_ast_node* right = pg_token_stream_ast_new(shared, 2, 0, c"right")
	pg_ast_node* child = pg_token_stream_ast_new(shared, 3, 0, c"prefix")
	pg_ast_add(left, child)
	pg_ast_add(right, child)
	pg_ast_set_metadata(child, c"binding", 7)
	pg_token_stream_free(shared)
	# Default clients still own and free their tree independently of the stream.
	pg_token_stream* independent = pg_token_stream_new()
	pg_ast_node* tree = pg_token_stream_ast_new(independent, 1, 0, c"tree")
	pg_ast_add(tree, pg_token_stream_ast_new(independent, 2, 0, c"child"))
	pg_token_stream_free(independent)
	assert_equal(1, pg_ast_child_count(tree))
	pg_ast_free(tree)
	assert_equal(0, debug_alloc_report_leaks())
	println(c"owned_ast_memory_test: OK")
	return 0
