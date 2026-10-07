# wbuild: x64
import lib.testing
import repl.incremental


type incremental_test_callback = fn(int) -> int


int incremental_test_ready


# One REPL engine per process; each scenario is its own incremental session.
# emit selects --ast-emit-retained lowering for the session (S2.4).
void incremental_test_begin(int emit):
	if (incremental_test_ready == 0):
		ast_expressions_mode = 2
		ast_required_mode = 1
		ast_retain_mode = 1
		repl_init()
		incremental_test_ready = 1
	ast_emit_retained_mode = emit
	incremental_init()


# End the session and remove its staged entries; the next session stages
# into a fresh directory.
void incremental_test_end():
	incremental_clear()
	repl_cleanup()
	free(repl_staging_dir)
	repl_staging_dir = 0


void incremental_suffix_emission(int emit):
	incremental_test_begin(emit)
	int base_code = codepos
	int base_table = table_pos
	list[char*] sources = new list[char*]
	sources.push(c"int inc_first(int n):\n\treturn n + 1\n")
	sources.push(c"int inc_second(int n):\n\treturn inc_first(n) * 2\n")
	sources.push(c"int inc_third(int n):\n\treturn inc_second(n) + 3\n")
	incremental_result result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(0, result.reused)
	assert_equal(3, result.compiled)
	int first_address = incremental_address(c"inc_first")
	int third_address = incremental_address(c"inc_third")
	assert_equal(13, (cast(incremental_test_callback*, third_address))(4))
	int unchanged_end = codepos
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(3, result.reused)
	assert_equal(0, result.compiled)
	assert_equal(unchanged_end, codepos)

	# A same-size edit changes behavior but retains the exact first function's
	# bytes and address. Retained tree IDs for that prefix stay valid too.
	int prefix_end = incremental_entries[1].before.codepos
	int prefix_nodes = incremental_entries[1].before.retained.nodes
	int prefix_types = incremental_entries[1].before.retained.types
	int prefix_bindings = incremental_entries[1].before.retained.bindings
	assert1(prefix_types > 0 && prefix_bindings > 0)
	retained_type* saved_type = retained_types[prefix_types - 1]
	retained_binding* saved_binding = retained_bindings[prefix_bindings - 1]
	char* saved_binding_name = strclone(saved_binding.name)
	int saved_binding_type = saved_binding.type
	char* prefix_bytes = cast(char*, malloc(prefix_end))
	for i in range(prefix_end): prefix_bytes[i] = code[i]
	sources[1] = c"int inc_second(int n):\n\treturn inc_first(n) * 4\n"
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(2, result.compiled)
	assert_equal(first_address, incremental_address(c"inc_first"))
	assert_bytes_equal(prefix_bytes, code, prefix_end)
	assert_equal(prefix_nodes, incremental_entries[1].before.retained.nodes)
	assert_equal(prefix_types, incremental_entries[1].before.retained.types)
	assert_equal(prefix_bindings, incremental_entries[1].before.retained.bindings)
	assert1(retained_types[prefix_types - 1] == saved_type)
	assert1(retained_bindings[prefix_bindings - 1] == saved_binding)
	assert_strings_equal(saved_binding_name, saved_binding.name)
	assert_equal(saved_binding_type, saved_binding.type)
	third_address = incremental_address(c"inc_third")
	assert_equal(23, (cast(incremental_test_callback*, third_address))(4))

	# Failed replacement retracts the old suffix, retains the valid prefix,
	# and leaves neither the failed function nor old downstream names callable.
	sources[1] = c"int inc_second(int n):\n\treturn +\n"
	result = incremental_update(sources)
	assert_equal(0, result.status)
	assert_equal(1, result.failed_index)
	assert_equal(1, result.reused)
	# The error left the return statement's walk open; the rollback that
	# retracted its node returned the record to the pool.
	assert_equal(0, retained_walks_used)
	assert_equal(0, result.compiled)
	assert_equal(1, incremental_entries.length)
	assert_equal(prefix_types, retained_types.length)
	assert_equal(prefix_bindings, retained_bindings.length)
	assert1(retained_types[prefix_types - 1] == saved_type)
	assert1(retained_bindings[prefix_bindings - 1] == saved_binding)
	assert_strings_equal(saved_binding_name, saved_binding.name)
	assert_equal(saved_binding_type, saved_binding.type)
	assert_equal(0, incremental_address(c"inc_second"))
	assert_equal(0, incremental_address(c"inc_third"))
	assert_equal(5, (cast(incremental_test_callback*, first_address))(4))
	assert_bytes_equal(prefix_bytes, code, prefix_end)
	sources[1] = c"int inc_second(int n):\n\treturn inc_first(n) * 6\n"
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(2, result.compiled)
	third_address = incremental_address(c"inc_third")
	assert_equal(33, (cast(incremental_test_callback*, third_address))(4))

	# Deletion removes definitions and machine code without any re-emission.
	sources.pop()
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(2, result.reused)
	assert_equal(0, result.compiled)
	assert_equal(0, incremental_address(c"inc_third"))
	# Append compiles just one definition; changing the first recompiles all.
	sources.push(c"int inc_third(int n):\n\treturn inc_second(n) + 3\n")
	result = incremental_update(sources)
	assert_equal(2, result.reused)
	assert_equal(1, result.compiled)
	sources[0] = c"int inc_first(int n):\n\treturn n + 2\n"
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(0, result.reused)
	assert_equal(3, result.compiled)
	third_address = incremental_address(c"inc_third")
	assert_equal(39, (cast(incremental_test_callback*, third_address))(4))

	# Insertion in the middle preserves the first function and re-emits the
	# inserted definition and its old suffix, even when calls are independent.
	list[char*] inserted = new list[char*]
	inserted.push(sources[0])
	inserted.push(c"int inc_middle(int n):\n\tint total = 0\n\twhile (n > 0):\n\t\ttotal = total + n\n\t\tn = n - 1\n\treturn total\n")
	inserted.push(sources[1])
	inserted.push(sources[2])
	result = incremental_update(inserted)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(3, result.compiled)
	int middle_address = incremental_address(c"inc_middle")
	assert_equal(10, (cast(incremental_test_callback*, middle_address))(4))
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(2, result.compiled)
	assert_equal(0, incremental_address(c"inc_middle"))
	inserted.free()
	third_address = incremental_address(c"inc_third")

	# Unsupported syntax is rejected before invalidation, even if a local has
	# the spelling of an unsafe keyword. Existing valid code stays callable.
	int before_rejection = codepos
	char* good = sources[1]
	sources[1] = c"int inc_second(int import):\n\timport lib.file\n\treturn 1\n"
	result = incremental_update(sources)
	assert_equal(0, result.status)
	assert_equal(1, result.failed_index)
	assert_equal(before_rejection, codepos)
	assert_equal(39, (cast(incremental_test_callback*, third_address))(4))
	sources[1] = good
	# Same-state no-op cannot hide a changed compiler mode or ABI.
	bounds_mode = 1 - bounds_mode
	result = incremental_update(sources)
	assert_equal(0, result.status)
	assert_equal(before_rejection, codepos)
	bounds_mode = 1 - bounds_mode
	int saved_word_size = word_size
	word_size = 16
	result = incremental_update(sources)
	assert_equal(0, result.status)
	word_size = saved_word_size
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(3, result.reused)

	free(prefix_bytes)
	free(saved_binding_name)
	sources.free()
	incremental_clear()
	assert_equal(base_code, codepos)
	assert_equal(base_table, table_pos)
	assert_equal(0, incremental_address(c"inc_first"))
	incremental_test_end()


void test_incremental_suffix_emission():
	incremental_suffix_emission(0)


# The same session with every statement and expression emitted from the
# retained forest (--ast-emit-retained); the walk pools drain after each
# update, including the failed one.
void test_incremental_suffix_emission_retained():
	int walked = ast_retained_statements_emitted
	incremental_suffix_emission(1)
	assert1(ast_retained_statements_emitted > walked)
	assert_equal(0, retained_walks_used)
	ast_emit_retained_mode = 0


# S2.4: a definition whose bytes changed but whose retained tree did not keeps
# its compiled function and its suffix. Run in both lowering modes.
void incremental_tree_reuse(int emit):
	incremental_test_begin(emit)
	list[char*] sources = new list[char*]
	sources.push(c"int tree_first(int n):\n\treturn n + 1 # one\n")
	sources.push(c"int tree_second(int n):\n\tint k = n * 2\n\tif (k > 3):\n\t\tk = k - 1\n\treturn tree_first(k) + 1\n")
	sources.push(c"int tree_third(int n):\n\treturn tree_second(n) * 3\n")
	incremental_result result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(3, result.compiled)
	assert_equal(0, result.tree_probed)
	int first_address = incremental_address(c"tree_first")
	int second_address = incremental_address(c"tree_second")
	int third_address = incremental_address(c"tree_third")
	assert_equal(27, (cast(incremental_test_callback*, third_address))(4))
	int end_code = codepos
	int end_table = table_pos
	int end_nodes = retained_nodes.length
	char* image = cast(char*, malloc(end_code))
	for i in range(end_code): image[i] = code[i]

	# Comment edits and trailing blanks: every definition is kept, nothing is
	# emitted, and the probes leave no trace in the session.
	sources[0] = c"int tree_first(int n):\n\treturn n + 1 # plus one, reworded\n"
	sources[1] = c"int tree_second(int n):\t\n\tint k = n * 2   \n\tif (k > 3): # large\n\t\tk = k - 1\n\treturn tree_first(k) + 1\n"
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(3, result.reused)
	assert_equal(0, result.compiled)
	assert_equal(2, result.tree_probed)
	assert_equal(2, result.tree_reused)
	assert_equal(end_code, codepos)
	assert_equal(end_table, table_pos)
	assert_equal(end_nodes, retained_nodes.length)
	assert_bytes_equal(image, code, end_code)
	assert_equal(first_address, incremental_address(c"tree_first"))
	assert_equal(second_address, incremental_address(c"tree_second"))
	assert_equal(27, (cast(incremental_test_callback*, third_address))(4))
	if (emit): assert_equal(0, retained_walks_used)
	# The new spelling is now the kept one: no probe the second time.
	result = incremental_update(sources)
	assert_equal(3, result.reused)
	assert_equal(0, result.tree_probed)

	# A comment line moves every later line: the tree's positions differ, so
	# the definition and its suffix recompile (without a probe).
	sources[1] = c"int tree_second(int n):\n\t# doubled\n\tint k = n * 2\n\tif (k > 3):\n\t\tk = k - 1\n\treturn tree_first(k) + 1\n"
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(2, result.compiled)
	assert_equal(0, result.tree_probed)
	third_address = incremental_address(c"tree_third")
	assert_equal(27, (cast(incremental_test_callback*, third_address))(4))

	# A code change is never a candidate, even one of the same length.
	sources[0] = c"int tree_first(int n):\n\treturn n + 2 # plus one, reworded\n"
	result = incremental_update(sources)
	assert_equal(0, result.reused)
	assert_equal(3, result.compiled)
	assert_equal(0, result.tree_probed)
	third_address = incremental_address(c"tree_third")
	assert_equal(30, (cast(incremental_test_callback*, third_address))(4))

	# A blank line that becomes spaces passes the layout check, but its
	# compile warns: the muted probe is discarded and the recompile reports
	# the warning once.
	sources[2] = c"int tree_third(int n):\n\n\treturn tree_second(n) * 3\n"
	result = incremental_update(sources)
	assert_equal(2, result.reused)
	assert_equal(1, result.compiled)
	# (The tokenizer reports space indentation once per line number for the
	# whole process, so forget an earlier session's report.)
	spaces_warned_line = -1
	int warnings = warning_count
	sources[2] = c"int tree_third(int n):\n  \n\treturn tree_second(n) * 3\n"
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(2, result.reused)
	assert_equal(1, result.compiled)
	assert_equal(1, result.tree_probed)
	assert_equal(0, result.tree_reused)
	assert_equal(warnings + 1, warning_count)
	third_address = incremental_address(c"tree_third")
	assert_equal(30, (cast(incremental_test_callback*, third_address))(4))

	# The trees decide: two compiled definitions with different trees compare
	# unequal, and a definition compares equal with itself.
	incremental_side a
	incremental_side b
	a.node_base = incremental_entries[0].before.retained.nodes
	a.table_base = incremental_entries[0].before.table_pos
	a.binding_base = incremental_entries[0].before.retained.bindings
	incremental_side_collect(&a, incremental_entries[0].before.retained.sources, incremental_entries[1].before.retained.nodes, incremental_entries[1].before.retained.bindings)
	b.node_base = incremental_entries[2].before.retained.nodes
	b.table_base = incremental_entries[2].before.table_pos
	b.binding_base = incremental_entries[2].before.retained.bindings
	incremental_side_collect(&b, incremental_entries[2].before.retained.sources, incremental_end.retained.nodes, incremental_end.retained.bindings)
	assert1(a.nodes.length > 0)
	assert1(b.nodes.length > 0)
	assert_equal(0, incremental_trees_equal(&a, &b))
	assert_equal(1, incremental_trees_equal(&a, &a))
	incremental_side_free(&a)
	incremental_side_free(&b)

	free(image)
	sources.free()
	incremental_test_end()


void test_incremental_retained_tree_reuse():
	incremental_tree_reuse(0)


void test_incremental_retained_tree_reuse_emitted():
	incremental_tree_reuse(1)
	ast_emit_retained_mode = 0


# Without the retained forest there is no tree: only equal bytes are kept.
void test_incremental_tree_reuse_needs_forest():
	assert_equal(1, incremental_layout_equal(c"int a(int n):\n\treturn n\n", c"int a(int n):\n\treturn n # same\n"))
	assert_equal(0, incremental_layout_equal(c"int a(int n):\n\treturn n\n", c"int a(int n):\n\t\treturn n\n"))
	char* layout = incremental_layout(c"int a(int n): # head\n\treturn n \t\r\n\n")
	assert_strings_equal(c"int a(int n):\n\treturn n\n\n", layout)
	free(layout)
	incremental_test_begin(0)
	int saved_ast = ast_expressions_mode
	int saved_required = ast_required_mode
	int saved_retain = ast_retain_mode
	incremental_clear()
	ast_expressions_mode = 0
	ast_required_mode = 0
	ast_retain_mode = 0
	incremental_init()
	list[char*] sources = new list[char*]
	sources.push(c"int plain_first(int n):\n\treturn n + 1\n")
	sources.push(c"int plain_second(int n):\n\treturn plain_first(n) * 2\n")
	incremental_result result = incremental_update(sources)
	assert_equal(2, result.compiled)
	sources[0] = c"int plain_first(int n):\n\treturn n + 1 # one\n"
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(0, result.reused)
	assert_equal(2, result.compiled)
	assert_equal(0, result.tree_probed)
	int second = incremental_address(c"plain_second")
	assert_equal(10, (cast(incremental_test_callback*, second))(4))
	sources.free()
	incremental_test_end()
	ast_expressions_mode = saved_ast
	ast_required_mode = saved_required
	ast_retain_mode = saved_retain


void test_incremental_admission():
	list[char*] names = new list[char*]
	assert1(incremental_admit(c"import lib.file\n", names) == 0)
	assert1(incremental_admit(c"int global = 1\n", names) == 0)
	assert1(incremental_admit(c"int prototype(int n)\n", names) == 0)
	assert1(incremental_admit(c"int a(int const):\n\tconst int n = 1\n\treturn n\n", names) == 0)
	assert1(incremental_admit(c"int a(int int):\n\treturn int\n", names) == 0)
	assert1(incremental_admit(c"int a(int bool):\n\treturn bool\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\tif n n:\n\treturn n\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\tn:\n\treturn n\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\treturn *n\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\t(n)\n\t*n = 1\n\treturn n\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\treturn (n)()\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\treturn 123()\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\treturn n\n\t()\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\treturn n()\n", names) == 0)
	assert1(incremental_admit(c"int a(int var):\n\tvar x = 3\n\treturn var\n", names) == 0)
	assert1(incremental_admit(c"int a(int defer):\n\tdefer return defer\n", names) == 0)
	assert1(incremental_admit(c"int __repl_0(int n):\n\treturn n\n", names) == 0)
	assert1(incremental_admit(c"int print(int n):\n\treturn n\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\treturn n\nint b():\n\treturn 3\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\treturn n\n int escaped_global = 1\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\treturn n[0]\n", names) == 0)
	assert1(incremental_admit(c"int a(int n):\n\treturn from_json(n)\n", names) == 0)
	char* accepted = incremental_admit(c"int a(int n):\n\tint total = 0\n\twhile (n > 0):\n\t\ttotal = total + n\n\t\tn = n - 1\n\treturn total\n", names)
	assert_strings_equal(c"a", accepted)
	free(accepted)
	names.free()
