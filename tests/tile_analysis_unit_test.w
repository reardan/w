# wbuild: x64
import lib.testing
import lib.str
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


void test_tile_plan_vector_mapping_is_bijective():
	tile_unit_init()
	# Every supported width, including partial passes on either side of 256.
	for width in range(1, 1025):
		tile_program* program = tile_unit_program(width)
		tile_analyze(program)
		int host = codepos
		int body = ptx_body_pos
		int module = ptx_module_pos
		int depth = stack_pos
		tile_lowering_plan* plan = tile_plan(program)
		assert1(program.plan == plan)
		assert1(tile_plan(program) == plan)
		assert_equal(256, plan.threads)
		assert_equal(width, plan.logical_width)
		assert_equal(256, plan.lane_stride)
		assert_equal((width + 255) / 256, plan.lane_passes)
		assert_equal(2, plan.element_shift)
		assert_equal(0, plan.dot_count)
		assert_equal(0, plan.shared_bytes)
		assert1(plan.dots == 0)
		for element in range(width):
			int thread = tile_plan_thread(plan, element)
			int lane_pass = tile_plan_pass(plan, element)
			assert1(thread >= 0 && thread < plan.threads)
			assert1(lane_pass >= 0 && lane_pass < plan.lane_passes)
			assert_equal(element, tile_plan_element(plan, thread, lane_pass))
		assert_equal(host, codepos)
		assert_equal(body, ptx_body_pos)
		assert_equal(module, ptx_module_pos)
		assert_equal(depth, stack_pos)


tile_node* tile_unit_zero():
	tile_node* node = tile_node_new(tile_zero)
	node.args = tile_unit_literal(16)
	node.args.next = tile_unit_literal(16)
	return node


tile_node* tile_unit_dot(tile_node* left, tile_node* right):
	tile_node* node = tile_node_new(tile_dot)
	node.args = left
	left.next = right
	return node


void tile_unit_assert_dot_plan(tile_lowering_plan* plan, tile_node* node, int id):
	tile_dot_plan* dot = tile_plan_dot(plan, node)
	assert1(dot != 0)
	assert1(dot.node == node)
	assert_equal(id, dot.id)
	assert_equal(16, dot.k_extent)
	assert_equal(2, dot.stage_thread_shift)
	assert_equal(6, dot.row_shift)
	assert_equal(2, dot.col_shift)
	assert_equal(id * 2, dot.left.id)
	assert_equal(id * 2 + 1, dot.right.id)
	assert_equal(id * 2048, dot.left.offset_bytes)
	assert_equal(id * 2048 + 1024, dot.right.offset_bytes)
	assert_equal(1024, dot.left.size_bytes)
	assert_equal(1024, dot.right.size_bytes)
	assert_equal(4, dot.left.alignment)
	assert_equal(4, dot.right.alignment)
	assert_equal(4, dot.left.element_stride)
	assert_equal(4, dot.right.element_stride)
	assert_equal(64, dot.left.row_stride)
	assert_equal(64, dot.right.row_stride)
	assert_equal(tile_sync_stage_ready, dot.stage_ready.phase)
	assert_equal(tile_sync_reuse_ready, dot.reuse_ready.phase)
	assert_equal(tile_sync_block, dot.stage_ready.scope)
	assert_equal(tile_sync_block, dot.reuse_ready.scope)
	assert_equal(0, dot.stage_ready.barrier_id)
	assert_equal(0, dot.reuse_ready.barrier_id)


void test_tile_plan_nested_dots_branches_and_reanalysis():
	tile_unit_init()
	tile_program* program = tile_unit_program(1)
	int pointer_type = type_get_next_pointer(float32_type)
	tile_binding* output = tile_unit_capture(program, c"output", pointer_type)
	tile_node* inner = tile_unit_dot(tile_unit_zero(), tile_unit_zero())
	tile_node* outer = tile_unit_dot(inner, tile_unit_zero())
	tile_node* alternate = tile_unit_dot(tile_unit_zero(), tile_unit_zero())
	tile_node* after = tile_unit_dot(tile_unit_zero(), tile_unit_zero())
	tile_node* condition = tile_node_new(tile_if)
	condition.left = tile_unit_literal(1)
	condition.body = tile_unit_matrix_store(output, outer)
	condition.otherwise = tile_unit_matrix_store(output, alternate)
	tile_node* loop = tile_node_new(tile_for)
	loop.binding = tile_binding_new(program, c"step", tile_binding_loop, type_lookup(c"int"))
	loop.left = tile_unit_literal(0)
	loop.right = tile_unit_literal(2)
	loop.body = condition
	loop.next = tile_unit_matrix_store(output, after)
	program.body = loop
	tile_analyze(program)
	tile_lowering_plan* plan = tile_plan(program)
	assert_equal(4, plan.dot_count)
	assert_equal(8192, plan.shared_bytes)
	assert_equal(program.shared_bytes, plan.shared_bytes)
	assert_equal(16, plan.matrix_rows)
	assert_equal(16, plan.matrix_cols)
	assert_equal(4, plan.row_shift)
	assert_equal(15, plan.col_mask)
	assert_equal(1, plan.lane_passes)
	for thread in range(256):
		assert_equal(thread / 16, tile_plan_row(plan, thread))
		assert_equal(thread % 16, tile_plan_col(plan, thread))
		assert_equal(thread, tile_plan_row(plan, thread) * 16 + tile_plan_col(plan, thread))
	tile_unit_assert_dot_plan(plan, inner, 0)
	tile_unit_assert_dot_plan(plan, outer, 1)
	tile_unit_assert_dot_plan(plan, alternate, 2)
	tile_unit_assert_dot_plan(plan, after, 3)
	assert1(plan.dots.node == inner)
	assert1(plan.dots.next.node == outer)
	assert1(plan.dots.next.next.node == alternate)
	assert1(plan.dots_tail.node == after)
	assert1(plan.dots_tail.next == 0)
	assert1(tile_plan_dot(plan, condition) == 0)
	# Cached lowering has no parser state, and semantic reanalysis invalidates it.
	assert1(tile_plan(program) == plan)
	tile_analyze(program)
	assert1(program.plan == 0)
	tile_lowering_plan* rebuilt = tile_plan(program)
	assert1(rebuilt != plan)
	assert_equal(plan.shared_bytes, rebuilt.shared_bytes)
	assert_equal(plan.dot_count, rebuilt.dot_count)
	tile_unit_assert_dot_plan(rebuilt, inner, 0)
	tile_unit_assert_dot_plan(rebuilt, after, 3)


void test_tile_plan_cache_survives_arena_suffix_rollback():
	tile_unit_init()
	tile_program* program = tile_unit_program(1)
	tile_binding* output = tile_unit_capture(program, c"output", type_get_next_pointer(float32_type))
	tile_node* node = tile_unit_dot(tile_unit_zero(), tile_unit_zero())
	program.body = tile_unit_matrix_store(output, node)
	tile_analyze(program)
	# The syntax owner survives this checkpoint, but its newly cached plan
	# does not. Overwrite the reclaimed address before asking to lower again.
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	tile_lowering_plan* discarded = tile_plan(program)
	int generation = program.plan_generation
	retained_rollback(&checkpoint)
	assert1(retained_arena_generation != generation)
	char* poison = retained_arena_alloc(sizeof(tile_lowering_plan))
	assert1(poison == cast(char*, discarded))
	for i in range(sizeof(tile_lowering_plan)): poison[i] = 127
	tile_lowering_plan* rebuilt = tile_plan(program)
	assert1(rebuilt != discarded)
	assert1(tile_plan(program) == rebuilt)
	assert_equal(retained_arena_generation, program.plan_generation)
	assert_equal(256, rebuilt.threads)
	assert_equal(1, rebuilt.dot_count)
	assert_equal(2048, rebuilt.shared_bytes)
	tile_unit_assert_dot_plan(rebuilt, node, 0)


void test_tile_ptx_consumes_shared_buffers_and_sync_plan():
	tile_unit_init()
	tile_program* program = tile_unit_program(1)
	program.kernel_name = c"tile_plan_consumer_probe"
	tile_binding* output = tile_unit_capture(program, c"output", type_get_next_pointer(float32_type))
	tile_node* node = tile_unit_dot(tile_unit_zero(), tile_unit_zero())
	program.body = tile_unit_matrix_store(output, node)
	tile_analyze(program)
	tile_lowering_plan* plan = tile_plan(program)
	tile_dot_plan* dot = plan.dots
	# Deliberately artificial plan values prove PTX consumes the contract.
	# This PTX is inspected only, never loaded or run on a GPU.
	dot.left.id = 20
	dot.right.id = 21
	dot.left.alignment = 8
	dot.right.alignment = 16
	dot.left.size_bytes = 2048
	dot.right.size_bytes = 4096
	dot.stage_thread_shift = 3
	dot.row_shift = 7
	dot.col_shift = 3
	dot.left.element_stride = 8
	dot.right.row_stride = 128
	dot.k_extent = 3
	dot.stage_ready.barrier_id = 2
	dot.reuse_ready.barrier_id = 3
	int start = ptx_module_pos
	tile_ptx_emit(program)
	char* emitted = ptx_module_buf + start
	assert1(contains(emitted, c".shared .align 8 .b8 __tile_a10[2048];"))
	assert1(contains(emitted, c".shared .align 16 .b8 __tile_b10[4096];"))
	assert1(contains(emitted, c"mov.u64 %tsa, __tile_a10;"))
	assert1(contains(emitted, c"mov.u64 %tsb, __tile_b10;"))
	assert1(contains(emitted, c"shl.b64 %tscratch, %ttid, 3;"))
	assert1(contains(emitted, c"shl.b64 %tscratch, %trow, 7;"))
	assert1(contains(emitted, c"shl.b64 %tscratch, %tcol, 3;"))
	assert1(contains(emitted, c"ld.f32 %tfa, [%tsa+16];"))
	assert1(contains(emitted, c"ld.f32 %tfb, [%tsb+256];"))
	assert1(!contains(emitted, c"ld.f32 %tfa, [%tsa+24];"))
	assert1(!contains(emitted, c"ld.f32 %tfb, [%tsb+384];"))
	assert1(contains(emitted, c"bar.sync 2;"))
	assert1(contains(emitted, c"bar.sync 3;"))
	assert1(!contains(emitted, c"bar.sync 0;"))
