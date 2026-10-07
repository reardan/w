# wbuild: x64
# wbuild: step="bin/ast_retained_memory_test" env="W_DEBUG_ALLOC=1"
import compiler.module_dependencies
import lib.assert


void test_source_versions():
	char* path = strclone(c"owned.w")
	for i in range(10000): retained_source_byte(path, i, 'a' + i % 26)
	int source = retained_source_id(path)
	free(path)
	int outer = retained_enter(retained_function, c"owned.w", 0, 1, 1, c"outer")
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	for i in range(3000):
		int node = retained_enter(retained_statement, c"owned.w", i, 1, i + 1, c"pass")
		retained_leave(node, i + 1)
	retained_source_byte(c"discard.w", 0, 'x')
	int newer = retained_source_begin(c"owned.w")
	assert1(newer != source)
	assert_equal(newer, retained_source_id(c"owned.w"))
	assert_equal(1, retained_source_byte(c"owned.w", 0, 'z'))
	assert_equal(0, retained_source_byte(c"owned.w", 0, 'q'))
	assert_equal('a', retained_sources[source].bytes[0])
	assert_equal('z', retained_sources[newer].bytes[0])
	retained_rollback(&checkpoint)
	assert_equal(checkpoint.nodes, retained_nodes.length)
	assert_equal(checkpoint.sources, retained_sources.length)
	assert_equal(outer, retained_parent)
	# The path index falls back to the surviving older version.
	assert_equal(source, retained_source_id(c"owned.w"))
	assert_equal(-1, retained_source_find(c"discard.w"))
	assert_strings_equal(c"owned.w", retained_sources[source].path)
	assert_equal(10000, retained_sources[source].length)
	for i in range(10000): assert_equal('a' + i % 26, retained_sources[source].bytes[i])
	retained_leave(outer, 10000)


# Nodes and copied text live in session chunks: rollback is a high-water
# mark that keeps surviving records in place and reuses retracted slots.
void test_arena_high_water():
	int source = retained_source_begin(c"arena.w")
	int root = retained_sources[source].root
	for i in range(1500): retained_add(retained_statement, root, source, i, 1, 1, c"kept")
	retained_node* survivor = retained_nodes[1200]
	char* kept_name = survivor.name
	# Equal spellings share one interned copy owned by the session.
	assert1(retained_nodes[1201].name == kept_name)
	assert_strings_equal(c"kept", kept_name)
	assert_equal(1500, retained_sources[source].top_level.length)
	char* buffer = cast(char*, malloc(retained_text_chunk))
	for i in range(retained_text_chunk): buffer[i] = 'a' + i % 26
	char* kept_text = retained_text_copy(buffer, 40000)
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	int first_retracted = retained_nodes.length
	for i in range(2500): retained_add(retained_statement, root, source, i, 1, 1, c"retracted")
	retained_node* reused = retained_nodes[first_retracted]
	# Records never span a chunk; the largest record fills one exactly.
	char* large = retained_text_copy(buffer, retained_text_chunk - 1)
	char* small = retained_text_copy(buffer, 100000)
	assert_equal('a', large[0])
	assert_equal(0, large[retained_text_chunk - 1])
	assert_equal(0, small[100000])
	assert1(retained_text_mark > 2 * retained_text_chunk)
	retained_rollback(&checkpoint)
	assert_equal(first_retracted, retained_nodes.length)
	assert_equal(checkpoint.text, retained_text_mark)
	assert_equal(1500, retained_sources[source].top_level.length)
	assert1(retained_nodes[1200] == survivor)
	assert1(survivor.name == kept_name)
	for i in range(40000): assert_equal('a' + i % 26, kept_text[i])
	int again = retained_add(retained_statement, root, source, 0, 1, 1, c"kept")
	assert_equal(first_retracted, again)
	assert1(retained_nodes[again] == reused)
	assert1(retained_nodes[again].name == kept_name)
	assert1(retained_text_copy(buffer, 10) == kept_text + 40001)
	free(buffer)


int main():
	malloc_force_debug_mode()
	retained_clear()
	ast_retain_mode = 1
	test_source_versions()
	module_dependency_graph* graph = module_dependencies_build()
	retained_clear()
	module_dependencies_free(graph)
	retained_clear()
	test_arena_high_water()
	retained_clear()
	ast_retain_mode = 0
	assert_equal(0, debug_alloc_report_leaks())
	return 0
