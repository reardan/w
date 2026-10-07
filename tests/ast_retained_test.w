# wbuild: x64
import lib.testing
import lib.file
import repl.core


void test_retained_production_lifetimes():
	retained_clear()
	ast_retain_mode = 1
	ast_expressions_mode = 2
	repl_init()
	char* path = cstr(f"/tmp/w_retained_{getpid()}.w")
	char* source = c"int retained_one(int first):\n\tif (first):\n\t\treturn first + 1\n\treturn 0\n\nint retained_two(int other):\n\treturn other + 2\n"
	assert1(file_write_text(path, source))
	assert1(compile_input_file(path))
	close(file)
	int source_id = retained_source_id(path)
	retained_source* saved_source = retained_sources[source_id]
	assert_equal(strlen(source), saved_source.length)
	assert_bytes_equal(source, saved_source.bytes, saved_source.length)
	unlink(path)
	free(path)
	# Function scope exit and the second declaration have recycled the
	# symbol-table slots. The first operand still owns its original binding.
	assert1(sym_probe(c"first") < 0)
	int one = -1
	int two = -1
	int first_uses = 0
	int nested_statements = 0
	for i in range(retained_node_count()):
		retained_node* node = retained_node_at(i)
		if (node.source != source_id): continue
		if (node.kind == retained_expression):
			assert1(retained_node_at(node.parent).start <= node.start)
			assert1(retained_node_at(node.parent).end >= node.end)
		if (node.kind == retained_function):
			if (strcmp(node.name, c"retained_one") == 0): one = i
			if (strcmp(node.name, c"retained_two") == 0): two = i
		if ((node.kind == retained_statement) && (retained_node_at(node.parent).kind == retained_statement)):
			nested_statements = nested_statements + 1
		if (node.binding_name != 0):
			if (strcmp(node.binding_name, c"first") == 0):
				first_uses = first_uses + 1
				assert_strings_equal(c"int", node.result_type)
				assert_strings_equal(saved_source.path, node.binding_file)
				assert_equal('A', node.binding_scope)
				assert_equal(1, node.binding_line)
	assert1(one >= 0 && two >= 0)
	assert1(first_uses >= 2)
	assert1(nested_statements >= 2)
	assert_equal(retained_declaration, retained_node_at(retained_node_at(one).parent).kind)
	assert_strings_equal(c"retained_one", retained_node_at(retained_node_at(one).parent).name)

	repl_result result = repl_eval(c"retained_one(5) + retained_two(6)")
	assert_equal(1, result.status)
	assert_equal(14, result.value)
	int nodes = retained_node_count()
	int sources = retained_sources.length
	int parent = retained_parent
	# Failure after valid earlier statements must release all nodes/sources
	# in the entry, including the unfinished containing statement/function.
	result = repl_eval(c"int retained_bad(int n):\n\tif (n):\n\t\treturn n + 1\n\treturn retained_missing\n")
	assert_equal(0, result.status)
	assert_equal(nodes, retained_node_count())
	assert_equal(sources, retained_sources.length)
	assert_equal(parent, retained_parent)
	assert_strings_equal(c"retained_one", retained_node_at(one).name)
	assert_bytes_equal(source, saved_source.bytes, saved_source.length)
	result = repl_eval(c"retained_one(9)")
	assert_equal(1, result.status)
	assert_equal(10, result.value)

	int literal_base = retained_node_count()
	result = repl_eval(c"s\"a\\x00b\".length")
	assert_equal(1, result.status)
	assert_equal(3, result.value)
	int literals = 0
	for i in range(literal_base, retained_node_count()):
		retained_node* node = retained_node_at(i)
		if (node.literal_text != 0):
			assert_equal(3, node.literal_length)
			assert_equal('a', node.literal_text[0])
			assert_equal(0, node.literal_text[1])
			assert_equal('b', node.literal_text[2])
			literals = literals + 1
	assert_equal(1, literals)

	# Reset uses the same checkpoint path as the debugger's evaluator.
	repl_genesis_checkpoint()
	nodes = retained_node_count()
	sources = retained_sources.length
	result = repl_eval(c"int retained_after_reset = 7")
	assert_equal(1, result.status)
	assert1(retained_node_count() > nodes)
	assert_equal(1, repl_reset_to_genesis())
	assert_equal(nodes, retained_node_count())
	assert_equal(sources, retained_sources.length)
	retained_clear()
	assert1(retained_node_count() == 0)
	assert1(retained_sources == 0)
	assert_equal(-1, retained_parent)
	ast_retain_mode = 0
