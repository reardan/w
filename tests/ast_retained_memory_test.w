# wbuild: x64
import compiler.module_dependencies
import lib.assert


int main():
	malloc_force_debug_mode()
	retained_clear()
	ast_retain_mode = 1
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
	assert_equal(1, retained_source_byte(c"owned.w", 0, 'z'))
	assert_equal(0, retained_source_byte(c"owned.w", 0, 'q'))
	assert_equal('a', retained_sources[source].bytes[0])
	assert_equal('z', retained_sources[newer].bytes[0])
	retained_rollback(&checkpoint)
	assert_equal(checkpoint.nodes, retained_nodes.length)
	assert_equal(checkpoint.sources, retained_sources.length)
	assert_equal(outer, retained_parent)
	assert_strings_equal(c"owned.w", retained_sources[source].path)
	assert_equal(10000, retained_sources[source].length)
	for i in range(10000): assert_equal('a' + i % 26, retained_sources[source].bytes[i])
	retained_leave(outer, 10000)
	module_dependency_graph* graph = module_dependencies_build()
	retained_clear()
	module_dependencies_free(graph)
	retained_clear()
	ast_retain_mode = 0
	assert_equal(0, debug_alloc_report_leaks())
	return 0
