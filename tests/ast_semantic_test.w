# wbuild: x64
import lib.testing
import lib.file
import repl.core


int semantic_find_declaration(char* name, int start):
	for i in range(start, retained_node_count()):
		retained_node* node = retained_node_at(i)
		if ((node.kind == retained_declaration) && (strcmp(node.name, name) == 0)): return i
	return -1


void test_semantic_owned_graph():
	retained_clear()
	ast_retain_mode = 1
	ast_expressions_mode = 2
	repl_init()
	char* path = cstr(f"/tmp/w_semantic_{getpid()}.w")
	char* dependency = cstr(f"bin.w_semantic_dep_{getpid()}")
	char* dependency_module = strclone(dependency)
	str_replace(dependency_module, '.', '/')
	char* dependency_path = cstr(f"bin/w_semantic_dep_{getpid()}.w")
	assert1(file_write_text(dependency_path, c"int semantic_imported_value():\n\treturn 19\n"))
	char* prefix = cstr(f"import {dependency} as semantic_dependency\nimport {dependency}\nimport lib.lib as semantic_lib\n\n")
	char* source = strjoin(prefix, c"enum SemanticColor:\n\tSemanticRed = 7\n\tSemanticBlue = 11\n\nstruct SemanticLink:\n\tSemanticLink* next\n\tint value\n\nint semantic_first(int same):\n\tif (same):\n\t\treturn same + 1\n\treturn same\n\nint semantic_second(int same):\n\treturn same + 2\n")
	free(prefix)
	assert1(file_write_text(path, source))
	int begin = retained_node_count()
	assert1(compile_input_file(path))
	close(file)
	unlink(path)
	free(path)
	unlink(dependency_path)
	free(dependency_path)
	free(source)
	int imports = 0
	for i in range(begin, retained_node_count()):
		retained_node* node = retained_node_at(i)
		if (node.kind != retained_import): continue
		assert_equal(retained_module, retained_node_at(node.parent).kind)
		assert1(node.end > node.start)
		assert1(node.line > 0 && node.column > 0)
		if (strcmp(node.name, dependency) == 0):
			assert_strings_equal(dependency_module, node.import_path)
			if (imports == 0): assert_strings_equal(c"semantic_dependency", node.import_alias)
			else: assert1(node.import_alias == 0)
		else:
			assert_strings_equal(c"lib.lib", node.name)
			assert_strings_equal(c"lib/lib", node.import_path)
			assert_strings_equal(c"semantic_lib", node.import_alias)
		imports = imports + 1
	assert_equal(3, imports)
	free(dependency)
	free(dependency_module)
	int color_declaration = semantic_find_declaration(c"SemanticColor", begin)
	assert1(color_declaration >= 0)
	retained_type* color = retained_types[retained_node_at(color_declaration).semantic_type]
	assert_equal(2, color.constants.length)
	assert_strings_equal(c"SemanticRed", color.constants[0].name)
	assert_equal(7, color.constants[0].value)
	assert_strings_equal(c"SemanticBlue", color.constants[1].name)
	assert_equal(11, color.constants[1].value)
	int declaration = semantic_find_declaration(c"SemanticLink", begin)
	assert1(declaration >= 0)
	int original = retained_node_at(declaration).semantic_type
	assert1(original >= 0)
	retained_type* type = retained_types[original]
	assert_strings_equal(c"SemanticLink", type.name)
	assert_equal(2, type.fields.length)
	assert_strings_equal(c"next", type.fields[0].name)
	assert_strings_equal(c"value", type.fields[1].name)
	assert_equal(0, type.fields[0].offset)
	assert_equal(word_size, type.fields[1].offset)
	retained_type* pointer = retained_types[type.fields[0].type]
	assert_equal(1, pointer.pointer_level)
	assert_equal(original, pointer.target)
	int first = -1
	int second = -1
	int first_count = 0
	for i in range(begin, retained_node_count()):
		retained_node* node = retained_node_at(i)
		if ((node.kind != retained_expression) || (node.binding < 0)): continue
		retained_binding* binding = retained_bindings[node.binding]
		if (strcmp(binding.name, c"same") != 0): continue
		assert1(binding.owner >= 0)
		assert1(node.line > 0 && node.column > 0)
		assert_equal('A', binding.scope)
		char* function_name = retained_node_at(binding.owner).name
		if (strcmp(function_name, c"semantic_first") == 0):
			if (first < 0): first = node.binding
			assert_equal(first, node.binding)
			first_count = first_count + 1
		else:
			assert_strings_equal(c"semantic_second", function_name)
			second = node.binding
	assert_equal(3, first_count)
	assert1(first >= 0 && second >= 0 && first != second)
	int first_declaration = semantic_find_declaration(c"semantic_first", begin)
	retained_binding* function = retained_bindings[retained_node_at(first_declaration).binding]
	assert_equal(1, function.parameters.length)
	assert_strings_equal(c"int", retained_types[function.return_type].name)
	assert_strings_equal(c"int", retained_types[function.parameters[0]].name)

	# Replace a record at the same production type index with another shape.
	# The existing semantic graph, including its recursive edge, is immutable.
	begin = retained_node_count()
	repl_result result = repl_eval(c"struct SemanticLink:\n\tint replacement\n")
	assert_equal(1, result.status)
	declaration = semantic_find_declaration(c"SemanticLink", begin)
	assert1(declaration >= 0)
	int replacement = retained_node_at(declaration).semantic_type
	assert1(replacement >= 0 && replacement != original)
	assert_equal(1, retained_types[replacement].fields.length)
	assert_strings_equal(c"replacement", retained_types[replacement].fields[0].name)
	assert_equal(2, type.fields.length)
	assert_equal(original, pointer.target)
	assert_strings_equal(c"value", type.fields[1].name)

	# A failed entry retracts all semantic identities created during its probe.
	int types = retained_types.length
	int bindings = retained_bindings.length
	result = repl_eval(c"int semantic_fail(int argument):\n\tint temporary = argument + 1\n\treturn missing_semantic_name\n")
	assert_equal(0, result.status)
	assert_equal(types, retained_types.length)
	assert_equal(bindings, retained_bindings.length)
	assert_equal(original, pointer.target)
	result = repl_eval(c"semantic_first(4) + semantic_second(5) + semantic_imported_value()")
	assert_equal(1, result.status)
	assert_equal(31, result.value)
	retained_clear()
	assert1(retained_types == 0 && retained_bindings == 0)
	ast_retain_mode = 0
