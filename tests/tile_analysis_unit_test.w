# wbuild: x64
import lib.testing
import repl.core


int tile_unit_initialized


void tile_unit_init():
	if (tile_unit_initialized): return
	repl_init()
	tile_unit_initialized = 1


tile_node* tile_unit_literal(int value):
	tile_node* node = tile_node_new(tile_literal)
	node.value = value
	return node


tile_node* tile_unit_reference(tile_binding* binding):
	tile_node* node = tile_node_new(tile_reference)
	node.binding = binding
	return node


tile_program* tile_unit_program(int width):
	tile_program* program = cast(tile_program*, tile_owned_zero(sizeof(tile_program)))
	program.width = width
	program.capture_count = 1
	program.bound = tile_unit_literal(33)
	program.tile_binding = tile_binding_new(program, c"index", tile_binding_index, type_lookup(c"int"))
	return program


tile_binding* tile_unit_capture(tile_program* program, char* name, int type):
	tile_binding* binding = tile_binding_new(program, name, tile_binding_capture, type)
	binding.capture_slot = program.capture_count
	program.capture_count += 1
	return binding


tile_node* tile_unit_index(tile_program* program, tile_binding* pointer_type):
	tile_node* node = tile_node_new(tile_index)
	node.left = tile_unit_reference(pointer_type)
	node.right = tile_unit_reference(program.tile_binding)
	return node


tile_node* tile_unit_binary(int op, tile_node* left, tile_node* right):
	tile_node* node = tile_node_new(tile_binary)
	node.op = op
	node.left = left
	node.right = right
	return node


void test_tile_analysis_records_shapes_and_memory_order():
	tile_unit_init()
	tile_program* program = tile_unit_program(1024)
	int pointer_type = type_lookup_next_pointer(float32_type)
	if (pointer_type < 0): pointer_type = type_get_next_pointer(float32_type)
	tile_binding* input = tile_unit_capture(program, c"input", pointer_type)
	tile_binding* output = tile_unit_capture(program, c"output", pointer_type)
	tile_binding* alpha = tile_unit_capture(program, c"alpha", float32_type)
	tile_node* load = tile_unit_index(program, input)
	tile_node* product = tile_unit_binary('*', tile_unit_reference(alpha), load)
	tile_node* sum = tile_unit_binary('+', product, tile_unit_literal(2))
	tile_node* saved = tile_node_new(tile_declare)
	saved.binding = tile_binding_new(program, c"value", tile_binding_local, -1)
	saved.left = sum
	tile_node* store = tile_node_new(tile_assign)
	store.left = tile_unit_index(program, output)
	store.right = tile_unit_reference(saved.binding)
	saved.next = store
	program.body = saved
	tile_analyze(program)
	assert_equal(1, program.analyzed)
	assert_equal(0, program.matrix_mode)
	assert_equal(1, saved.binding.rank)
	assert_equal(1024, saved.binding.cols)
	assert_equal(float32_type, saved.binding.type)
	assert_equal(0, saved.binding.uniform)
	assert_equal(1, load.masked)
	assert_equal(1, load.effect_order)
	assert_equal(1, store.masked)
	assert_equal(2, store.effect_order)
	assert_equal(2, program.effect_count)
	# A semantic consumer may analyze the same retained body again, with no
	# tokenizer or live symbol table involvement and identical inferred types.
	tile_analyze(program)
	assert_equal(2, program.effect_count)
	assert_equal(1024, saved.binding.cols)
	assert_equal(float32_type, saved.binding.type)


tile_node* tile_unit_matrix_load(tile_binding* pointer_type):
	tile_node* node = tile_node_new(tile_load)
	node.args = tile_unit_reference(pointer_type)
	tile_node* tail = node.args
	for i in range(8):
		int value = 16
		if (i < 2): value = 0
		else if (i == 3): value = 1
		tail.next = tile_unit_literal(value)
		tail = tail.next
	return node


tile_node* tile_unit_matrix_store(tile_binding* pointer_type, tile_node* value):
	tile_node* node = tile_unit_matrix_load(pointer_type)
	node.kind = tile_store
	tile_node* tail = node.args
	for i in range(6): tail = tail.next
	tail.next = value
	return node


void test_tile_analysis_stages_dot_under_uniform_control():
	tile_unit_init()
	tile_program* program = tile_unit_program(1)
	int pointer_type = type_get_next_pointer(float32_type)
	tile_binding* input = tile_unit_capture(program, c"input", pointer_type)
	tile_binding* output = tile_unit_capture(program, c"output", pointer_type)
	tile_node* accumulator = tile_node_new(tile_declare)
	accumulator.binding = tile_binding_new(program, c"acc", tile_binding_local, -1)
	accumulator.left = tile_node_new(tile_zero)
	accumulator.left.args = tile_unit_literal(16)
	accumulator.left.args.next = tile_unit_literal(16)
	tile_node* loop = tile_node_new(tile_for)
	loop.binding = tile_binding_new(program, c"k", tile_binding_loop, type_lookup(c"int"))
	loop.left = tile_unit_literal(0)
	loop.right = tile_unit_literal(3)
	tile_node* dot = tile_node_new(tile_dot)
	dot.args = tile_unit_matrix_load(input)
	dot.args.next = tile_unit_matrix_load(input)
	tile_node* add = tile_node_new(tile_assign)
	add.op = '+'
	add.left = tile_unit_reference(accumulator.binding)
	add.right = dot
	tile_node* condition = tile_node_new(tile_if)
	condition.left = tile_unit_binary('<', tile_unit_reference(loop.binding), tile_unit_literal(2))
	condition.body = add
	loop.body = condition
	accumulator.next = loop
	loop.next = tile_unit_matrix_store(output, tile_unit_reference(accumulator.binding))
	program.body = accumulator
	tile_analyze(program)
	assert_equal(1, program.matrix_mode)
	assert_equal(2048, program.shared_bytes)
	assert_equal(4, program.effect_count)
	assert_equal(1, dot.args.effect_order)
	assert_equal(2, dot.args.next.effect_order)
	assert_equal(3, dot.effect_order)
	assert_equal(4, loop.next.effect_order)
	assert_equal(1, loop.binding.uniform)
	assert_equal(1, condition.left.uniform)
	assert_equal(16, dot.rows)
	assert_equal(16, dot.cols)
	assert_equal(2, accumulator.binding.rank)
	assert_equal(float32_type, dot.type)
	tile_analyze(program)
	assert_equal(2048, program.shared_bytes)
	assert_equal(4, program.effect_count)


void test_tile_analysis_scalar_control_and_types():
	tile_unit_init()
	tile_program* program = tile_unit_program(17)
	tile_binding* bound = tile_unit_capture(program, c"bound", type_lookup(c"int"))
	program.bound = tile_unit_binary('+', tile_unit_reference(bound), tile_unit_literal(1))
	tile_node* local = tile_node_new(tile_declare)
	local.binding = tile_binding_new(program, c"factor", tile_binding_local, float32_type)
	local.left = tile_unit_literal(2)
	tile_node* condition = tile_node_new(tile_if)
	condition.left = tile_unit_binary(tile_op_and, tile_unit_literal(1), tile_unit_reference(bound))
	tile_node* assignment = tile_node_new(tile_assign)
	assignment.left = tile_unit_reference(local.binding)
	assignment.right = tile_node_new(tile_unary)
	assignment.right.op = '-'
	assignment.right.left = tile_unit_literal(3)
	condition.body = assignment
	condition.otherwise = tile_node_new(tile_assign)
	condition.otherwise.left = tile_unit_reference(local.binding)
	condition.otherwise.right = tile_unit_literal(4)
	local.next = condition
	program.body = local
	tile_analyze(program)
	assert_equal(0, program.effect_count)
	assert_equal(0, local.binding.rank)
	assert_equal(1, local.binding.uniform)
	assert_equal(float32_type, local.binding.type)
	assert_equal(type_lookup(c"int"), condition.left.type)
	assert_equal(-1, tile_scalar_type(float64_type))
	assert_equal(0, tile_float_pointer(type_get_next_pointer(type_lookup(c"int"))))
	assert_equal(1, tile_float_pointer(type_get_next_pointer(float32_type)))
