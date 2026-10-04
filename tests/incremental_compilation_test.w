# wbuild: x64
import lib.testing
import repl.incremental


void test_incremental_suffix_emission():
	ast_expressions_mode = 2
	ast_required_mode = 1
	ast_retain_mode = 1
	repl_init()
	incremental_init()
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
	assert_equal(13, third_address(4))
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
	char* prefix_bytes = malloc(prefix_end)
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
	assert_equal(23, third_address(4))

	# Failed replacement retracts the old suffix, retains the valid prefix,
	# and leaves neither the failed function nor old downstream names callable.
	sources[1] = c"int inc_second(int n):\n\treturn +\n"
	result = incremental_update(sources)
	assert_equal(0, result.status)
	assert_equal(1, result.failed_index)
	assert_equal(1, result.reused)
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
	assert_equal(5, first_address(4))
	assert_bytes_equal(prefix_bytes, code, prefix_end)
	sources[1] = c"int inc_second(int n):\n\treturn inc_first(n) * 6\n"
	result = incremental_update(sources)
	assert_equal(1, result.status)
	assert_equal(1, result.reused)
	assert_equal(2, result.compiled)
	third_address = incremental_address(c"inc_third")
	assert_equal(33, third_address(4))

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
	assert_equal(39, third_address(4))

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
	assert_equal(10, middle_address(4))
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
	assert_equal(39, third_address(4))
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
	retained_clear()
	repl_cleanup()


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
