# wbuild: x64
import compiler.compiler
import lib.assert


# Registration owns the syntax even before an exit binds it. Exercise the
# same registry truncation used by function completion and REPL recovery.
int memory_defer_tree():
	defer_syntax_tree* tree = new defer_syntax_tree()
	defer_syntax_node* call = new defer_syntax_node()
	call.kind = 2
	call.name = strclone(c"record")
	defer_syntax_node* value = new defer_syntax_node()
	value.kind = 1
	value.name = strclone(c"late_local")
	call.arguments = value
	value.allocated_next = call
	tree.root = call
	tree.allocated = value
	return cast(int, tree)


int main():
	malloc_force_debug_mode()
	ast_retain_mode = 0
	for i in range(128):
		defer_record_span(strclone(c"owned-defer.w"), 0, 0, 0)
		defer_spans[0].tree = memory_defer_tree()
		int surviving = defer_spans[0].tree
		defer_record_span(strclone(c"discarded-defer.w"), 20, 1, 0)
		defer_spans[1].tree = memory_defer_tree()
		defer_tree_pending = memory_defer_tree()
		defer_truncate(1)
		assert_equal(0, defer_tree_pending)
		assert_equal(1, defer_count())
		assert_equal(surviving, defer_spans[0].tree)
		defer_syntax_tree* tree = cast(defer_syntax_tree*, surviving)
		assert_strings_equal(c"record", tree.root.name)
		assert_strings_equal(c"late_local", tree.root.arguments.name)
		defer_reset()
		assert_equal(0, defer_count())
	defer_spans.free()
	defer_spans = 0
	assert_equal(0, debug_alloc_report_leaks())
	return 0
