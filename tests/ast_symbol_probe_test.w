# wbuild: x64
import lib.testing
import compiler.compiler


void test_ast_pointer_probe_records_are_transactional():
	word_size = __word_size__
	push_basic_types()
	int base = type_push_size(c"ast_pointer_probe_base", word_size)
	expression_ast tree
	tree.types_base = type_count()
	tree.types_count = 0
	tree.pending_buffer_types = 0
	int first = ast_expression_pointer_type(&tree, base, 10)
	int second = ast_expression_pointer_type(&tree, first, 11)
	assert_equal(tree.types_base, first)
	assert_equal(first + 1, second)
	assert_equal(first, ast_expression_pointer_type(&tree, base, 12))
	assert_equal(2, tree.types_count)
	assert_equal(2, type_get_pointer_level(second))
	assert_equal(base, type_lookup(c"ast_pointer_probe_base"))
	ast_expression_restore_types(&tree)
	assert_equal(tree.types_base, type_count())
	assert_equal(-1, type_lookup_next_pointer(base))
	assert_equal(base, type_lookup(c"ast_pointer_probe_base"))
	ast_expression_commit_pointer(&tree, 0)
	ast_expression_commit_pointer(&tree, 1)
	assert_equal(first, type_lookup_next_pointer(base))
	assert_equal(second, type_lookup_next_pointer(first))
	assert1(type_record(first) != &tree.pointer_types[0])
	assert1(type_record(second) != &tree.pointer_types[1])
	# A pending array promotion must not reorder new type records.
	tree.types_base = type_count()
	tree.types_count = 0
	tree.pending_buffer_types = 1
	assert_equal(-1, ast_expression_pointer_type(&tree, second, 13))
	assert_equal(tree.types_base, type_count())
	# Capacity failure leaves only arena-owned records to roll back.
	tree.pending_buffer_types = 0
	int current = second
	for i in range(16):
		current = ast_expression_pointer_type(&tree, current, 20 + i)
		assert1(current >= 0)
	assert_equal(-1, ast_expression_pointer_type(&tree, current, 40))
	ast_expression_restore_types(&tree)
	assert_equal(tree.types_base, type_count())
	assert_equal(-1, type_lookup_next_pointer(second))


void test_ast_symbol_probe_preserves_usage_and_scope_state():
	verbosity = -1
	filename = 0
	sym_declare(c"ast_probe_local", 1, 'L', 0, 1)
	int outer = sym_index_offset(sym_index_count - 1)
	int outer_index = sym_index_count - 1
	int outer_end = table_pos
	sym_index_lint[outer_index] = 1
	int calls = sym_lookup_calls
	int steps = sym_lookup_steps
	assert_equal(outer, sym_probe(c"ast_probe_local"))
	assert_equal(-1, sym_probe(c"ast_probe_absent"))
	assert_equal(1, cast(int, sym_index_lint[outer_index]))
	assert_equal(calls, sym_lookup_calls)
	assert_equal(steps, sym_lookup_steps)

	sym_declare(c"ast_probe_local", 2, 'L', 1, 1)
	int inner = sym_index_offset(sym_index_count - 1)
	int count = sym_index_count
	assert_equal(inner, sym_probe(c"ast_probe_local"))
	table_pos = outer_end
	assert_equal(outer, sym_probe(c"ast_probe_local"))
	assert_equal(count, sym_index_count)
	assert_equal(count - 1, sym_name_index[c"ast_probe_local"])
	assert_equal(1, cast(int, sym_index_lint[outer_index]))
	assert_equal(calls, sym_lookup_calls)
	assert_equal(outer, sym_lookup(c"ast_probe_local"))
	assert_equal(count - 1, sym_index_count)
	assert_equal(2, cast(int, sym_index_lint[outer_index]))

	# Debugger eval retires scratch bindings without truncating the table.
	int start = table_pos
	sym_declare(c"ast_probe_local", 2, 'L', 1, 1)
	assert_equal(1, sym_index_unbind(start))
	table[start] = '_'
	assert_equal(outer, sym_probe(c"ast_probe_local"))
