# wbuild: x64
import lib.testing
import lib.process
import lib.file
import lib.utf8
import lib.str
import tools.manifest_json


process_result* tree_test_run(char* path):
	char** args = strv_new(6)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"x64")
	strv_set(args, 2, c"tree")
	strv_set(args, 3, c"--json")
	strv_set(args, 4, c"--quiet")
	strv_set(args, 5, path)
	process_result* result = process_run(args[0], args, 0, 0, 30000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


void test_owned_tree_query():
	char* path = cstr(f"bin/ast_tree_query_{getpid()}.w")
	assert1(file_write_text(path, c"int tree_answer(int input):\n\treturn input + 7\nint main():\n\treturn tree_answer(3) - 10\n"))
	process_result* result = tree_test_run(path)
	assert_equal(0, result.status)
	assert_strings_equal(c"", result.stderr_text)
	process_result* repeated = tree_test_run(path)
	assert_equal(0, repeated.status)
	assert_strings_equal(result.stdout_text, repeated.stdout_text)
	process_result_free(repeated)
	char* line = result.stdout_text
	int declarations = 0
	int expressions = 0
	int node_count = -1
	int source_count = -1
	int type_count = -1
	int binding_count = -1
	int function_binding = -1
	int found_signature = 0
	int nodes = 0
	int dependencies = 0
	int locals = 0
	while (line[0]):
		int length = 0
		while ((line[length] != 0) && (line[length] != 10)): length = length + 1
		int ending = line[length]
		line[length] = 0
		json_value* row = json_parse(line)
		assert1(row != 0)
		char* record = jfield_string(row, c"record")
		assert1(record != 0)
		if (strcmp(record, c"tree") == 0):
			node_count = jfield_int(row, c"nodes", -1)
			source_count = jfield_int(row, c"sources", -1)
			type_count = jfield_int(row, c"types", -1)
			binding_count = jfield_int(row, c"bindings", -1)
			assert_equal(2, jfield_int(row, c"version", -1))
		if (strcmp(record, c"node") == 0):
			assert_equal(nodes, jfield_int(row, c"id", -1))
			nodes = nodes + 1
			int parent = jfield_int(row, c"parent", -2)
			int source = jfield_int(row, c"source", -1)
			int type = jfield_int(row, c"type", -2)
			int binding = jfield_int(row, c"binding", -2)
			assert1(parent >= -1 && parent < node_count)
			assert1(source >= 0 && source < source_count)
			assert1(type >= -1 && type < type_count)
			assert1(binding >= -1 && binding < binding_count)
			char* kind = jfield_string(row, c"kind")
			if (strcmp(kind, c"declaration") == 0):
				if (strcmp(jfield_string(row, c"name"), c"tree_answer") == 0):
					declarations = declarations + 1
					function_binding = binding
					assert1(binding >= 0)
			if (strcmp(kind, c"expression") == 0): expressions = expressions + 1
			if (strcmp(kind, c"local") == 0):
				assert1(binding >= 0)
				locals = locals + 1
		if (strcmp(record, c"dependency") == 0):
			int source = jfield_int(row, c"source", -1)
			int target = jfield_int(row, c"target", -1)
			int reasons = jfield_int(row, c"reasons", 0)
			assert1(source >= 0 && source < source_count)
			assert1(target >= 0 && target < source_count && source != target)
			assert1(reasons > 0 && reasons <= 7)
			dependencies = dependencies + 1
		if (strcmp(record, c"binding") == 0):
			int linkage = jfield_int(row, c"linkage", -1)
			assert1(linkage >= 0 && linkage < binding_count)
			if (strcmp(jfield_string(row, c"name"), c"tree_answer") == 0):
				assert_equal(function_binding, jfield_int(row, c"id", -1))
				assert1(jfield_int(row, c"return_type", -1) >= 0)
				assert_equal(1, json_array_length(jfield_array(row, c"parameters")))
				found_signature = found_signature + 1
		json_free(row)
		if (ending == 0): break
		line = line + length + 1
	assert_equal(1, declarations)
	assert1(expressions > 0)
	assert1(locals > 0)
	assert1(dependencies > 0)
	assert_equal(node_count, nodes)
	assert_equal(1, found_signature)
	process_result_free(result)
	# An invalid program produces diagnostics, never a partially usable tree.
	assert1(file_write_text(path, c"int main():\n\treturn tree_missing\n"))
	result = tree_test_run(path)
	assert1(result.status != 0)
	assert1(contains(result.stdout_text, c"\"severity\": \"error\"") != 0)
	assert1(contains(result.stdout_text, c"\"record\": \"tree\"") == 0)
	process_result_free(result)
	unlink(path)
	free(path)
