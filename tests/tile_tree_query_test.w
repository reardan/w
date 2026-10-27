# `w tree --json` reports analyzed tile facts: per-node shapes and bindings,
# one tile_program record per region, its bindings and its planned dots.
import lib.testing
import lib.process
import lib.file
import lib.str
import tools.manifest_json


char* tile_tree_source():
	return c"import lib.lib\nvoid __w_gpu_launch_tiles(char* name, int n, int width, int threads, char* vals, int count):\n\tpass\nvoid product(float32* a, float32* b, float32* c, int m, int n, int k, int programs):\n\tgpu[1] for tile in range(programs):\n\t\tint row = tile_program_id() * 64\n\t\tacc := tile_zero(64, 64)\n\t\tfor int block in range((k + 31) / 32):\n\t\t\tleft := tile_load(a, row, block * 32, k, 1, m, k, 64, 32)\n\t\t\tright := tile_load(b, block * 32, 0, n, 1, k, n, 32, 64)\n\t\t\tacc += dot(left, right)\n\t\ttile_store(c, row, 0, n, 1, m, n, acc * 2.0)\nvoid add(float32* a, float32* c, int n):\n\tgpu[512] for tile in range(n):\n\t\tc[tile] = a[tile] + 1\n\t\tif n > 0:\n\t\t\tc[tile] = -a[tile]\nint main():\n\treturn 0\n"


json_value* tile_tree_find(list[json_value*] rows, char* record, char* key, char* value):
	for i in range(rows.length):
		json_value* row = rows[i]
		if (strcmp(jfield_string(row, c"record"), record) != 0): continue
		char* text = jfield_string(row, key)
		if ((text != 0) && (strcmp(text, value) == 0)): return row
	return 0


json_value* tile_tree_node(list[json_value*] rows, int id):
	for i in range(rows.length):
		json_value* row = rows[i]
		if ((strcmp(jfield_string(row, c"record"), c"node") == 0) && (jfield_int(row, c"id", -1) == id)): return row
	return 0


void test_tile_tree_reports_analysis():
	char* path = f"bin/tile_tree_query_{getpid()}.w"
	assert1(file_write_text(path, tile_tree_source()))
	char** args = strv_new(9)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"x64")
	strv_set(args, 2, c"tree")
	strv_set(args, 3, c"--json")
	strv_set(args, 4, c"--quiet")
	strv_set(args, 5, c"--file")
	strv_set(args, 6, path)
	strv_set(args, 7, path)
	process_result* result = process_run(args[0], args, 0, 0, 60000)
	free(cast(void*, args))
	assert1(result != 0)
	assert_equal(0, result.status)
	list[json_value*] rows = new list[json_value*]
	list[char*] lines = split(result.stdout_text, 10)
	for i in range(lines.length):
		if (lines[i][0] != 0):
			json_value* row = json_parse(lines[i])
			assert1(row != 0)
			# Every tile record carries the selected source like a node does.
			if (starts_with(jfield_string(row, c"record"), c"tile_")): assert1(jfield_int(row, c"source", -2) >= 0)
			rows.push(row)
		free(lines[i])
	lines.free()
	# The matrix program: its plan, bindings and the fused dot.
	json_value* matrix = 0
	json_value* vector = 0
	for i in range(rows.length):
		json_value* row = rows[i]
		if (strcmp(jfield_string(row, c"record"), c"tile_program") != 0): continue
		if (jfield_int(row, c"matrix", -1) == 1): matrix = row
		else: vector = row
	assert1(matrix != 0)
	assert1(vector != 0)
	assert_equal(1, jfield_int(matrix, c"width", -1))
	assert_equal(1, jfield_int(matrix, c"analyzed", -1))
	assert_equal(22528, jfield_int(matrix, c"shared_bytes", -1))
	assert_equal(256, jfield_int(matrix, c"threads", -1))
	assert_equal(1, jfield_int(matrix, c"dots", -1))
	int program = jfield_int(matrix, c"node", -1)
	json_value* owner = tile_tree_node(rows, program)
	assert1(owner != 0)
	assert_strings_equal(c"gpu", jfield_string(owner, c"name"))
	assert_equal(512, jfield_int(vector, c"width", -1))
	assert_equal(2, jfield_int(vector, c"lane_passes", -1))
	assert_equal(0, jfield_int(vector, c"shared_bytes", -1))
	json_value* acc = tile_tree_find(rows, c"tile_binding", c"name", c"acc")
	assert1(acc != 0)
	assert_equal(program, jfield_int(acc, c"program", -1))
	assert_strings_equal(c"local", jfield_string(acc, c"kind"))
	assert_strings_equal(c"float32", jfield_string(acc, c"type"))
	assert_equal(2, jfield_int(acc, c"rank", -1))
	assert_equal(64, jfield_int(acc, c"rows", -1))
	assert_equal(64, jfield_int(acc, c"cols", -1))
	assert_equal(0, jfield_int(acc, c"uniform", -1))
	json_value* pointer = tile_tree_find(rows, c"tile_binding", c"name", c"b")
	assert_strings_equal(c"capture", jfield_string(pointer, c"kind"))
	assert_strings_equal(c"float32*", jfield_string(pointer, c"type"))
	assert1(jfield_int(pointer, c"capture_slot", -1) > 0)
	json_value* block = tile_tree_find(rows, c"tile_binding", c"name", c"block")
	assert_strings_equal(c"loop", jfield_string(block, c"kind"))
	assert_equal(1, jfield_int(block, c"uniform", -1))
	json_value* dot = tile_tree_find(rows, c"tile_dot", c"record", c"tile_dot")
	assert1(dot != 0)
	assert_equal(program, jfield_int(dot, c"program", -1))
	assert_equal(64, jfield_int(dot, c"m", -1))
	assert_equal(32, jfield_int(dot, c"k", -1))
	assert_equal(64, jfield_int(dot, c"n", -1))
	assert_equal(1, jfield_int(dot, c"fused", -1))
	assert_equal(12288, jfield_int(dot, c"right_offset", -1))
	assert_equal(320, jfield_int(dot, c"right_row_stride", -1))
	# The dot's node record carries its analyzed shape and effect order.
	json_value* node = tile_tree_node(rows, jfield_int(dot, c"node", -1))
	assert1(node != 0)
	assert_strings_equal(c"tile_expression", jfield_string(node, c"kind"))
	assert_strings_equal(c"dot", jfield_string(node, c"tile_op"))
	assert_strings_equal(c"float32", jfield_string(node, c"tile_type"))
	assert_equal(2, jfield_int(node, c"tile_rank", -1))
	assert_equal(64, jfield_int(node, c"tile_rows", -1))
	assert_equal(64, jfield_int(node, c"tile_cols", -1))
	assert1(jfield_int(node, c"tile_effect", 0) > 0)
	# Loads are masked effects; a reference names its binding.
	json_value* load = tile_tree_find(rows, c"node", c"tile_op", c"load")
	assert_equal(1, jfield_int(load, c"tile_masked", -1))
	assert_equal(32, jfield_int(load, c"tile_cols", -1))
	json_value* reference = tile_tree_find(rows, c"node", c"name", c"acc")
	assert_strings_equal(c"reference", jfield_string(reference, c"tile_op"))
	assert_equal(jfield_int(acc, c"id", -2), jfield_int(reference, c"tile_binding", -1))
	json_value* program_id = tile_tree_find(rows, c"node", c"tile_op", c"program_id")
	assert_equal(1, jfield_int(program_id, c"tile_uniform", -1))
	json_value* store = tile_tree_find(rows, c"node", c"tile_op", c"store")
	assert_strings_equal(c"tile_statement", jfield_string(store, c"kind"))
	char*[9] ops
	ops[0] = c"literal"
	ops[1] = c"binary"
	ops[2] = c"unary"
	ops[3] = c"index"
	ops[4] = c"declare"
	ops[5] = c"assign"
	ops[6] = c"for"
	ops[7] = c"if"
	ops[8] = c"zero"
	for i in range(9): assert1(tile_tree_find(rows, c"node", c"tile_op", ops[i]) != 0)
	# Each region's index binding has the region width as its vector extent.
	int indices = 0
	for i in range(rows.length):
		json_value* row = rows[i]
		if (strcmp(jfield_string(row, c"record"), c"tile_binding") != 0): continue
		if (strcmp(jfield_string(row, c"kind"), c"index") != 0): continue
		int width = 1
		if (jfield_int(row, c"program", -1) != program): width = 512
		assert_equal(width, jfield_int(row, c"cols", -1))
		indices = indices + 1
	assert_equal(2, indices)
	for i in range(rows.length): json_free(rows[i])
	rows.free()
	process_result_free(result)
	unlink(path)
	free(path)
