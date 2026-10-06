# wbuild: x64
import lib.testing
import lib.process
import lib.file
import lib.utf8
import lib.str
import tools.manifest_json


# Filters (--file <name>, --no-expressions) go before the program path.
process_result* tree_test_run_filtered(char* path, char* file, int no_expressions):
	char** args = strv_new(9)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"x64")
	strv_set(args, 2, c"tree")
	strv_set(args, 3, c"--json")
	strv_set(args, 4, c"--quiet")
	int at = 5
	if (file != 0):
		strv_set(args, at, c"--file")
		strv_set(args, at + 1, file)
		at = at + 2
	if (no_expressions):
		strv_set(args, at, c"--no-expressions")
		at = at + 1
	strv_set(args, at, path)
	process_result* result = process_run(args[0], args, 0, 0, 30000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


process_result* tree_test_run(char* path):
	return tree_test_run_filtered(path, 0, 0)


# Every line of a filtered dump is a line of the full dump: the leading
# tree record keeps the session totals and no record is renumbered. Records
# that carry a source belong to the selected one; returns the node count.
int tree_test_check_filtered(map[char*, int] full_lines, process_result* result, int selected, int no_expressions):
	assert_equal(0, result.status)
	list[char*] lines = split(result.stdout_text, 10)
	assert1(lines.length > 1)
	int nodes = 0
	int sources = 0
	int declarations = 0
	for i in range(lines.length):
		char* line = lines[i]
		if (line[0] == 0): continue
		assert1(line in full_lines)
		if (i == 0): assert1(full_lines[line] == 0)
		json_value* row = json_parse(line)
		assert1(row != 0)
		char* record = jfield_string(row, c"record")
		if (strcmp(record, c"tree") != 0):
			int source = jfield_int(row, c"source", -2)
			if (strcmp(record, c"source") == 0): source = jfield_int(row, c"id", -2)
			if (selected >= 0): assert_equal(selected, source)
		if (strcmp(record, c"source") == 0): sources = sources + 1
		if (strcmp(record, c"node") == 0):
			nodes = nodes + 1
			char* kind = jfield_string(row, c"kind")
			if (no_expressions):
				assert1(strcmp(kind, c"expression") != 0)
				assert1(strcmp(kind, c"expression_group") != 0)
			if (strcmp(kind, c"declaration") == 0): declarations = declarations + 1
		json_free(row)
	if (selected >= 0): assert_equal(1, sources)
	assert1(declarations > 0)
	for i in range(lines.length): free(lines[i])
	lines.free()
	return nodes


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
	map[char*, int] full_lines = new map[char*, int]
	list[char*] all_lines = split(result.stdout_text, 10)
	for i in range(all_lines.length):
		full_lines[all_lines[i]] = i
		free(all_lines[i])
	all_lines.free()
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
	# Filters select records without renumbering them.
	int source_id = -1
	for key in full_lines:
		if (contains(key, c"\"record\": \"source\"") && contains(key, path)):
			json_value* source_row = json_parse(key)
			source_id = jfield_int(source_row, c"id", -1)
			json_free(source_row)
	assert1(source_id >= 0)
	result = tree_test_run_filtered(path, path, 0)
	int selected_nodes = tree_test_check_filtered(full_lines, result, source_id, 0)
	process_result_free(result)
	result = tree_test_run_filtered(path, path, 1)
	int declaration_nodes = tree_test_check_filtered(full_lines, result, source_id, 1)
	process_result_free(result)
	assert1(declaration_nodes < selected_nodes)
	result = tree_test_run_filtered(path, 0, 1)
	assert1(tree_test_check_filtered(full_lines, result, -1, 1) > declaration_nodes)
	process_result_free(result)
	result = tree_test_run_filtered(path, c"tree_query_no_such_source.w", 0)
	assert1(result.status != 0)
	assert1(contains(result.stderr_text, c"no compiled source matches --file") != 0)
	assert1(contains(result.stdout_text, c"\"record\": \"tree\"") == 0)
	process_result_free(result)
	full_lines.free()
	# An invalid program produces diagnostics, never a partially usable tree.
	assert1(file_write_text(path, c"int main():\n\treturn tree_missing\n"))
	result = tree_test_run(path)
	assert1(result.status != 0)
	assert1(contains(result.stdout_text, c"\"severity\": \"error\"") != 0)
	assert1(contains(result.stdout_text, c"\"record\": \"tree\"") == 0)
	process_result_free(result)
	unlink(path)
	free(path)
