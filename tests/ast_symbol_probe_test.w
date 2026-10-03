# wbuild: x64
import lib.testing
import compiler.compiler


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
