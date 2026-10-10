# wbuild: x64
import lib.testing
import repl.incremental_graph

type graph_callback = fn(int) -> int

int graph_test_ready


void graph_test_begin():
	if (graph_test_ready == 0):
		ast_expressions_mode = 2
		ast_required_mode = 1
		repl_init()
		graph_test_ready = 1
	incremental_graph_init()


void graph_test_end():
	incremental_graph_clear()
	repl_cleanup()
	free(repl_staging_dir)
	repl_staging_dir = 0


int graph_call(char* name, int n):
	int address = incremental_graph_address(name)
	assert1(address != 0)
	return (cast(graph_callback*, address))(n)


void test_independent_reuse_and_transitive_invalidation():
	graph_test_begin()
	list[char*] sources = new list[char*]
	sources.push(c"int graph_first(int n):\n\treturn n + 1\n")
	sources.push(c"int graph_other(int n):\n\treturn n * 10\n")
	sources.push(c"int graph_caller(int n):\n\treturn graph_first(n) * 2\n")
	sources.push(c"int graph_outer(int n):\n\treturn graph_caller(n) + 3\n")
	incremental_result result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(4, result.compiled)
	assert_equal(13, graph_call(c"graph_outer", 4))
	int other = incremental_graph_address(c"graph_other")
	int symbol = sym_probe(c"graph_other")
	int size = incremental_function_length(symbol)
	char* copy = cast(char*, malloc(size))
	char* original = cast(char*, other)
	for i in range(size): copy[i] = original[i]
	int old_end = codepos
	result = incremental_graph_update(sources)
	assert_equal(4, result.reused)
	assert_equal(0, result.compiled)
	assert_equal(old_end, codepos)

	sources[0] = c"int graph_first(int n):\n\treturn n + 7\n"
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(3, result.compiled)
	assert_equal(other, incremental_graph_address(c"graph_other"))
	assert_bytes_equal(copy, cast(char*, other), size)
	assert_equal(25, graph_call(c"graph_outer", 4))
	assert_equal(40, graph_call(c"graph_other", 4))
	assert1(codepos > old_end)

	# Removing an independent function and moving another definition across
	# it preserves both the remaining code and its addresses.
	list[char*] reordered = new list[char*]
	reordered.push(sources[0])
	reordered.push(sources[2])
	reordered.push(sources[3])
	reordered.push(sources[1])
	old_end = codepos
	result = incremental_graph_update(reordered)
	assert_equal(1, result.status)
	assert_equal(4, result.reused)
	assert_equal(0, result.compiled)
	assert_equal(old_end, codepos)
	reordered.pop()
	result = incremental_graph_update(reordered)
	assert_equal(3, result.reused)
	assert_equal(0, result.compiled)
	assert_equal(0, incremental_graph_address(c"graph_other"))
	assert_equal(old_end, codepos)
	result = incremental_graph_update(sources)
	assert_equal(3, result.reused)
	assert_equal(1, result.compiled)
	assert_equal(40, graph_call(c"graph_other", 4))
	free(copy)
	reordered.free()
	sources.free()
	graph_test_end()


void test_independent_update_failure_is_atomic():
	graph_test_begin()
	list[char*] sources = new list[char*]
	sources.push(c"int graph_base(int n):\n\treturn n + 1\n")
	sources.push(c"int graph_user(int n):\n\treturn graph_base(n) * 2\n")
	incremental_result result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	int address = incremental_graph_address(c"graph_base")
	int caller = incremental_graph_address(c"graph_user")
	int old_end = codepos
	int old_table = table_pos
	int old_sites = repl_sites_count
	int old_nodes = retained_node_count()

	# The first changed function compiles, the second fails. Neither its
	# symbol nor its queued call-site patches may escape the transaction.
	sources[0] = c"int graph_base(int n):\n\treturn n + 9\n"
	sources[1] = c"int graph_user(int n):\n\treturn +\n"
	result = incremental_graph_update(sources)
	assert_equal(0, result.status)
	assert_equal(0, result.compiled)
	assert_equal(old_end, codepos)
	assert_equal(old_table, table_pos)
	assert_equal(old_sites, repl_sites_count)
	assert_equal(old_nodes, retained_node_count())
	assert_equal(address, incremental_graph_address(c"graph_base"))
	assert_equal(caller, incremental_graph_address(c"graph_user"))
	assert_equal(10, graph_call(c"graph_user", 4))
	assert_equal(5, graph_call(c"graph_base", 4))
	sources[1] = c"int graph_user(int n):\n\treturn graph_base(n) * 2\n"
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(2, result.compiled)
	assert_equal(26, graph_call(c"graph_user", 4))

	# Removing a dependency fails admission before any code changes.
	list[char*] missing = new list[char*]
	missing.push(sources[1])
	old_end = codepos
	result = incremental_graph_update(missing)
	assert_equal(0, result.status)
	assert_equal(0, result.failed_index)
	assert_equal(old_end, codepos)
	assert_equal(26, graph_call(c"graph_user", 4))
	missing.free()
	# The prefix API cannot silently alter an independent session.
	result = incremental_update(sources)
	assert_equal(0, result.status)
	assert_equal(old_end, codepos)
	# Reuse is invalid if an emission option changes, even on a no-op update.
	int saved_opt = ast_opt_mode
	ast_opt_mode = 1 - saved_opt
	result = incremental_graph_update(sources)
	assert_equal(0, result.status)
	assert_equal(old_end, codepos)
	ast_opt_mode = saved_opt
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(2, result.reused)
	assert_equal(0, result.compiled)
	sources.free()
	graph_test_end()


void test_independent_recursion_and_signature_change():
	graph_test_begin()
	list[char*] sources = new list[char*]
	sources.push(c"int graph_recursive(int n):\n\tif (n <= 0):\n\t\treturn 1\n\treturn graph_recursive(n - 1) + 1\n")
	sources.push(c"int graph_uses(int n):\n\treturn graph_recursive(n)\n")
	incremental_result result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(5, graph_call(c"graph_uses", 4))
	sources[0] = c"int graph_recursive(int n):\n\tif (n <= 0):\n\t\treturn 2\n\treturn graph_recursive(n - 1) + 2\n"
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(2, result.compiled)
	assert_equal(10, graph_call(c"graph_uses", 4))
	# Recompile users when a signature changes, so the production type
	# checker rejects stale arity instead of reusing incompatible code.
	sources[0] = c"int graph_recursive(int n, int m):\n\treturn n + m\n"
	result = incremental_graph_update(sources)
	assert_equal(0, result.status)
	assert_equal(10, graph_call(c"graph_uses", 4))
	sources[1] = c"int graph_uses(int n):\n\treturn graph_recursive(n, 7)\n"
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(11, graph_call(c"graph_uses", 4))
	sources.free()
	graph_test_end()


void test_independent_code_capacity_failure_keeps_old_addresses():
	graph_test_begin()
	list[char*] sources = new list[char*]
	sources.push(c"int graph_capacity(int n):\n\treturn n + 3\n")
	incremental_result result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	int address = incremental_graph_address(c"graph_capacity")
	int old_end = codepos
	char* old_code = code
	int capacity = code_size
	# Exercise the fixed executable arena's exhaustion path without filling
	# eight megabytes with repeated definitions. The mapping stays allocated.
	code_size = codepos + 16
	sources[0] = c"int graph_capacity(int n):\n\treturn n + 9\n"
	result = incremental_graph_update(sources)
	code_size = capacity
	assert_equal(0, result.status)
	assert_equal(old_end, codepos)
	assert1(old_code == code)
	assert_equal(address, incremental_graph_address(c"graph_capacity"))
	assert_equal(7, graph_call(c"graph_capacity", 4))
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(13, graph_call(c"graph_capacity", 4))
	sources.free()
	graph_test_end()


void test_independent_inline_option_change_rejects_reuse():
	graph_test_begin()
	list[char*] sources = new list[char*]
	sources.push(c"int graph_inline_option(int n):\n\treturn n + 1\n")
	incremental_result result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	int old_end = codepos
	int old_inline = inline_requested
	inline_requested = 1 - old_inline
	result = incremental_graph_update(sources)
	assert_equal(0, result.status)
	assert_equal(old_end, codepos)
	inline_requested = old_inline
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(0, result.compiled)
	assert_equal(5, graph_call(c"graph_inline_option", 4))
	sources.free()
	graph_test_end()


void test_independent_owned_symbol_table_growth():
	graph_test_begin()
	list[char*] sources = new list[char*]
	sources.push(strclone(c"int graph_resize_kept(int n):\n\treturn n + 1\n"))
	incremental_result result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	int old_end = codepos
	int old_size = table_size
	int old_address = incremental_graph_address(c"graph_resize_kept")
	# Append-only definitions legitimately grow the compiler's symbol
	# allocation. Fill its remaining capacity with long, valid names.
	int suffix = (table_size - table_pos) / 255 + 512
	assert1(suffix < 4000)
	for i in range(255):
		string_builder* source = string_new()
		string_append(source, c"int graph_resize_")
		string_append_int(source, i)
		for j in range(suffix): string_append_char(source, 'a')
		string_append(source, c"(int n):\n\treturn n + 1\n")
		sources.push(source.data)
		free(source)
	char* last = sources[255]
	sources[255] = c"int graph_resize_bad(int n):\n\treturn +\n"
	result = incremental_graph_update(sources)
	assert_equal(0, result.status)
	assert1(table_size > old_size)
	assert_equal(old_end, codepos)
	assert_equal(old_address, incremental_graph_address(c"graph_resize_kept"))
	assert_equal(5, graph_call(c"graph_resize_kept", 4))
	# Rollback keeps the larger allocation; its identity must be accepted
	# as session-owned on a repaired update and on subsequent reuse.
	sources[255] = last
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(255, result.compiled)
	old_end = codepos
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(256, result.reused)
	assert_equal(0, result.compiled)
	assert_equal(old_end, codepos)
	assert_equal(old_address, incremental_graph_address(c"graph_resize_kept"))
	incremental_strings_free(sources)
	graph_test_end()


void test_independent_deleted_names_cannot_leak_through_locals():
	graph_test_begin()
	list[char*] sources = new list[char*]
	sources.push(c"int graph_delete_kept(int n):\n\treturn n + 1\n")
	char* removed = c"int graph_delete_removed(int n):\n\treturn n + 2\n"
	sources.push(removed)
	incremental_result result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	sources.pop()
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(0, incremental_graph_address(c"graph_delete_removed"))
	int kept = incremental_graph_address(c"graph_delete_kept")
	int old_end = codepos
	int old_table = table_pos
	# Admission collects local names before production compilation. A
	# later local must not admit a reference to the historical function.
	sources.push(c"int graph_delete_fresh(int n):\n\tint value = graph_delete_removed\n\tint graph_delete_removed = 3\n\treturn value\n")
	result = incremental_graph_update(sources)
	assert_equal(0, result.status)
	assert_equal(1, result.failed_index)
	assert_contains(result.message, c"reserved until session clear")
	assert_equal(old_end, codepos)
	assert_equal(old_table, table_pos)
	assert_equal(kept, incremental_graph_address(c"graph_delete_kept"))
	assert_equal(5, graph_call(c"graph_delete_kept", 4))
	assert_equal(0, incremental_graph_address(c"graph_delete_fresh"))
	# Intentionally conservative: even a correctly ordered local using
	# a deleted name is reserved. No hidden compiler symbol can bind it.
	char* local = c"int graph_delete_fresh(int n):\n\tint graph_delete_removed = 3\n\treturn graph_delete_removed\n"
	sources[1] = local
	result = incremental_graph_update(sources)
	assert_equal(0, result.status)
	assert_equal(1, result.failed_index)
	assert_equal(old_end, codepos)
	assert_equal(old_table, table_pos)
	# Reintroducing the function explicitly makes the name available;
	# the properly scoped local can then shadow it as ordinary W permits.
	sources[1] = removed
	sources.push(local)
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(2, result.compiled)
	assert_equal(3, graph_call(c"graph_delete_fresh", 0))
	sources.free()
	graph_test_end()
	# Clearing also releases the historical-name reservation.
	graph_test_begin()
	sources = new list[char*]
	sources.push(local)
	result = incremental_graph_update(sources)
	assert_equal(1, result.status)
	assert_equal(3, graph_call(c"graph_delete_fresh", 0))
	sources.free()
	graph_test_end()
