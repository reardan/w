# wbuild: x64
import lib.testing
import lib.file
import repl.core
import compiler.module_dependencies


int dependency_test_compile(char* suffix, char* text):
	char* path = cstr(f"bin/module_ir_{getpid()}_{suffix}.w")
	assert1(file_write_text(path, text))
	assert1(compile_input_file(path))
	close(file)
	int source = retained_source_id(filename)
	unlink(path)
	free(path)
	return source


int dependency_test_reasons(module_dependency_graph* graph, int source, int target):
	module_dependencies* module = graph.modules[source]
	for i in range(module.targets.length):
		if (module.targets[i] == target): return module.reasons[i]
	return 0


int dependency_test_contains(list[int] ids, int id):
	for i in range(ids.length):
		if (ids[i] == id): return 1
	return 0


void test_owned_module_dependency_analysis():
	retained_clear()
	ast_retain_mode = 1
	ast_expressions_mode = 2
	repl_init()
	char* dependency = cstr(f"bin/module_ir_{getpid()}_dependency.w")
	assert1(file_write_text(dependency, c"struct DependencyRecord:\n\tDependencyRecord* next\n\tint value\nint dependency_global = 4\nT dependency_identity[T](T input):\n\treturn input\n"))
	char* middle_text = cstr(f"import bin.module_ir_{getpid()}_dependency\nimport bin.module_ir_{getpid()}_dependency as dependency_alias\nint dependency_middle(int unused_parameter):\n\tDependencyRecord unused_record\n\tinferred_unused := 3\n\tif (1):\n\t\tint shadow = 1\n\tif (1):\n\t\tint shadow = 2\n\treturn dependency_identity(dependency_global) + inferred_unused - 3\n")
	int middle = dependency_test_compile(c"middle", middle_text)
	free(middle_text)
	int imported = -1
	for i in range(retained_sources.length):
		if (ends_with(retained_sources[i].path, dependency)): imported = i
	assert1(imported >= 0)
	# Separate roots need semantic edges even without an explicit import.
	int root = dependency_test_compile(c"root", c"int dependency_root():\n\treturn dependency_middle(0)\n")
	int unrelated = dependency_test_compile(c"unrelated", c"int dependency_unrelated():\n\treturn 99\n")
	char* cycle_a_path = cstr(f"bin/module_ir_{getpid()}_cycle_a.w")
	char* cycle_b_path = cstr(f"bin/module_ir_{getpid()}_cycle_b.w")
	char* cycle_a_text = cstr(f"import bin.module_ir_{getpid()}_cycle_b\n")
	char* cycle_b_text = cstr(f"import bin.module_ir_{getpid()}_cycle_a\n")
	assert1(file_write_text(cycle_a_path, cycle_a_text))
	assert1(file_write_text(cycle_b_path, cycle_b_text))
	dependency_test_compile(c"cycle_root", cycle_b_text)
	int cycle_a = -1
	int cycle_b = -1
	for i in range(retained_sources.length):
		if (ends_with(retained_sources[i].path, cycle_a_path)): cycle_a = i
		if (ends_with(retained_sources[i].path, cycle_b_path)): cycle_b = i
	assert1(cycle_a >= 0 && cycle_b >= 0)
	unlink(cycle_a_path)
	unlink(cycle_b_path)
	free(cycle_a_path)
	free(cycle_b_path)
	free(cycle_a_text)
	free(cycle_b_text)
	int prototype = dependency_test_compile(c"prototype", c"int dependency_forward(int argument);\n")
	int caller = dependency_test_compile(c"caller", c"int dependency_caller():\n\treturn dependency_forward(2)\n")
	int definition = dependency_test_compile(c"definition", c"int dependency_forward(int argument):\n\treturn argument + 8\n")
	int parameter = 0
	int record = 0
	int inferred = 0
	int shadow = 0
	int first_shadow = -1
	int first_parent = -1
	int imports = 0
	for i in range(retained_nodes.length):
		retained_node* node = retained_nodes[i]
		if (node.source != middle): continue
		if (node.kind == retained_import):
			assert_equal(imported, node.import_source)
			imports = imports + 1
		if ((node.kind == retained_expression) && (node.binding >= 0)):
			retained_binding* use = retained_bindings[node.binding]
			if (strcmp(use.name, c"inferred_unused") == 0): assert_equal(5, use.line)
		if (node.kind != retained_local): continue
		retained_binding* binding = retained_bindings[node.binding]
		assert1(binding.owner >= 0)
		if (strcmp(node.name, c"unused_parameter") == 0):
			parameter = parameter + 1
			assert_equal('A', binding.scope)
			assert_equal(3, binding.line)
			assert1(retained_nodes[node.parent].start <= node.start)
		if (strcmp(node.name, c"unused_record") == 0): record = record + 1
		if (strcmp(node.name, c"inferred_unused") == 0):
			inferred = inferred + 1
			assert_equal(5, binding.line)
			assert_equal(2, binding.column)
		if (strcmp(node.name, c"shadow") == 0):
			if (shadow == 0):
				first_shadow = node.binding
				first_parent = node.parent
			else:
				assert1(first_shadow != node.binding)
				assert1(first_parent != node.parent)
			shadow = shadow + 1
	assert_equal(2, imports)
	assert_equal(1, parameter)
	assert_equal(1, record)
	assert_equal(1, inferred)
	assert_equal(2, shadow)
	int forward = -1
	int defined = -1
	for i in range(retained_bindings.length):
		retained_binding* binding = retained_bindings[i]
		if (strcmp(binding.name, c"dependency_forward") != 0): continue
		if (binding.scope == 'U'): forward = i
		if (binding.scope == 'D'): defined = i
	assert1(forward >= 0 && defined >= 0 && forward != defined)
	assert_equal(retained_bindings[forward].linkage, retained_bindings[defined].linkage)
	# A failed nested import must restore resolver context as well as nodes.
	char* broken_path = cstr(f"bin/module_ir_{getpid()}_broken.w")
	assert1(file_write_text(broken_path, c"int broken_dependency():\n\treturn missing_module_dependency\n"))
	char* broken_import = cstr(f"import bin.module_ir_{getpid()}_broken")
	int bindings_before = retained_bindings.length
	int nodes_before = retained_nodes.length
	repl_result failed = repl_eval(broken_import)
	assert_equal(0, failed.status)
	assert_equal(bindings_before, retained_bindings.length)
	assert_equal(nodes_before, retained_nodes.length)
	assert1(retained_pending_import == 0)
	free(broken_import)
	unlink(broken_path)
	free(broken_path)
	# Redefinition has a new linkage identity and cannot rewrite the old
	# prototype/definition relation, including across failed suffixes.
	repl_result replacement = repl_eval(c"int dependency_forward(int argument):\n\treturn argument + 9\n")
	assert_equal(1, replacement.status)
	int replaced = -1
	for i in range(bindings_before, retained_bindings.length):
		if (strcmp(retained_bindings[i].name, c"dependency_forward") == 0): replaced = i
	assert1(replaced >= 0)
	assert1(retained_bindings[replaced].linkage != retained_bindings[defined].linkage)
	assert_equal(retained_bindings[forward].linkage, retained_bindings[defined].linkage)
	unlink(dependency)
	free(dependency)
	int code_before = codepos
	int symbols_before = table_pos
	int types_before = type_count()
	module_dependency_graph* graph = module_dependencies_build()
	assert_equal(code_before, codepos)
	assert_equal(symbols_before, table_pos)
	assert_equal(types_before, type_count())
	assert1(dependency_test_reasons(graph, cycle_a, cycle_b) & module_dependency_import)
	assert1(dependency_test_reasons(graph, cycle_b, cycle_a) & module_dependency_import)
	assert1(dependency_test_reasons(graph, middle, imported) & module_dependency_import)
	assert1(dependency_test_reasons(graph, middle, imported) & module_dependency_type)
	assert1(dependency_test_reasons(graph, root, middle) & module_dependency_binding)
	assert1(dependency_test_reasons(graph, caller, prototype) & module_dependency_binding)
	assert1(dependency_test_reasons(graph, caller, definition) & module_dependency_binding)
	list[int] changed = new list[int]
	changed.push(imported)
	changed.push(imported)
	list[int] invalid = module_dependencies_invalidate(graph, changed)
	assert1(dependency_test_contains(invalid, imported))
	assert1(dependency_test_contains(invalid, middle))
	assert1(dependency_test_contains(invalid, root))
	assert_equal(0, dependency_test_contains(invalid, unrelated))
	assert_equal(0, dependency_test_contains(invalid, caller))
	for i in range(1, invalid.length): assert1(invalid[i - 1] < invalid[i])
	invalid.free()
	changed.clear()
	changed.push(definition)
	invalid = module_dependencies_invalidate(graph, changed)
	assert1(dependency_test_contains(invalid, caller))
	invalid.free()
	# No source files remain, and the analysis result owns all of its data.
	retained_clear()
	invalid = module_dependencies_invalidate(graph, changed)
	assert1(dependency_test_contains(invalid, caller))
	assert1(ends_with(graph.modules[root].path, c"_root.w"))
	invalid.free()
	changed.free()
	module_dependencies_free(graph)
	ast_retain_mode = 0
	repl_cleanup()


void test_module_dependency_cycles_and_empty_graph():
	retained_clear()
	module_dependency_graph* empty = module_dependencies_build()
	list[int] changed = new list[int]
	list[int] invalid = module_dependencies_invalidate(empty, changed)
	assert_equal(0, invalid.length)
	invalid.free()
	module_dependencies_free(empty)
	retained_source_begin(c"a.w")
	retained_source_begin(c"b.w")
	retained_source_begin(c"c.w")
	module_dependency_graph* graph = module_dependencies_build()
	module_dependency_add(graph, 0, 1, module_dependency_import)
	module_dependency_add(graph, 1, 0, module_dependency_import)
	module_dependency_add(graph, 2, 1, module_dependency_type)
	module_dependency_add(graph, 2, 1, module_dependency_binding)
	assert_equal(1, graph.modules[2].targets.length)
	assert_equal(6, graph.modules[2].reasons[0])
	changed.push(0)
	invalid = module_dependencies_invalidate(graph, changed)
	assert_equal(3, invalid.length)
	invalid.free()
	changed.free()
	retained_clear()
	module_dependencies_free(graph)
