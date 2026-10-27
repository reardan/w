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
	assert_equal(16, dot.m_extent)
	assert_equal(16, dot.k_extent)
	assert_equal(16, dot.n_extent)
	assert_equal(0, dot.fused)
	assert_equal(id * 2, dot.left.id)
	assert_equal(id * 2 + 1, dot.right.id)
	# Every dot reuses the one shared region after its reuse barrier.
	assert_equal(0, dot.left.offset_bytes)
	assert_equal(1024, dot.right.offset_bytes)
	assert_equal(1024, dot.left.size_bytes)
	assert_equal(1024, dot.right.size_bytes)
	assert_equal(16, dot.left.alignment)
	assert_equal(16, dot.right.alignment)
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
	assert_equal(2048, plan.shared_bytes)
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
	plan.shared_bytes = 12345
	dot.left.offset_bytes = 4096
	dot.right.offset_bytes = 8192
	dot.left.row_stride = 72
	dot.right.row_stride = 128
	dot.left.element_stride = 8
	# Three K steps: staging then covers no left/right fragment (16x3 and
	# 3x16 are not whole fragments), so only the reduction reads appear.
	dot.k_extent = 3
	dot.stage_ready.barrier_id = 2
	dot.reuse_ready.barrier_id = 3
	int start = ptx_module_pos
	tile_ptx_emit(program)
	char* emitted = ptx_module_buf + start
	assert1(contains(emitted, c".shared .align 16 .b8 __tile_smem[12345];"))
	assert1(contains(emitted, c"mov.u64 %tsmem, __tile_smem;"))
	assert1(contains(emitted, c"mul.lo.u64 %tsa, %trow, 72;"))
	assert1(contains(emitted, c"mul.lo.u64 %tsb, %trow, 128;"))
	assert1(contains(emitted, c", [%tsa+4112];"))
	assert1(contains(emitted, c", [%tsb+8448];"))
	assert1(!contains(emitted, c", [%tsa+4120];"))
	assert1(!contains(emitted, c", [%tsb+8576];"))
	assert1(contains(emitted, c"fma.rn.f32 "))
	assert1(contains(emitted, c"bar.sync 2;"))
	assert1(contains(emitted, c"bar.sync 3;"))
	assert1(!contains(emitted, c"bar.sync 0;"))


tile_node* tile_unit_shaped_zero(int rows, int cols):
	tile_node* node = tile_node_new(tile_zero)
	node.args = tile_unit_literal(rows)
	node.args.next = tile_unit_literal(cols)
	return node


void test_tile_plan_fragment_mapping_is_bijective():
	tile_unit_init()
	tile_program* program = tile_unit_program(1)
	tile_analyze(program)
	tile_lowering_plan* plan = tile_plan(program)
	int[4] sizes
	sizes[0] = 16
	sizes[1] = 32
	sizes[2] = 64
	sizes[3] = 128
	for r in range(4):
		for c in range(4):
			int rows = sizes[r]
			int cols = sizes[c]
			int fragments = tile_plan_fragments(plan, rows, cols)
			assert_equal(rows * cols, fragments * plan.threads)
			char* seen = tile_owned_zero(rows * cols)
			for thread in range(plan.threads):
				for f in range(fragments):
					int row = tile_plan_fragment_row(plan, thread, cols, f)
					int col = tile_plan_fragment_col(plan, thread, cols, f)
					assert1(row >= 0 && row < rows && col >= 0 && col < cols)
					# Adjacent threads hold adjacent columns of the same row.
					assert_equal(tile_plan_row(plan, thread), row % 16)
					assert_equal(tile_plan_col(plan, thread), col % 16)
					assert_equal(0, seen[row * cols + col])
					seen[row * cols + col] = 1


void test_tile_plan_rectangular_dots_share_one_region():
	tile_unit_init()
	tile_program* program = tile_unit_program(1)
	tile_binding* output = tile_unit_capture(program, c"output", type_get_next_pointer(float32_type))
	# 128x16 * 16x128: left rows hold 16 words; right rows (128 words, a
	# multiple of 32) are padded by 16 words to keep warp rows bank-disjoint.
	tile_node* wide = tile_unit_dot(tile_unit_shaped_zero(128, 16), tile_unit_shaped_zero(16, 128))
	tile_node* deep = tile_unit_dot(tile_unit_shaped_zero(64, 32), tile_unit_shaped_zero(32, 64))
	tile_node* accumulator = tile_node_new(tile_declare)
	accumulator.binding = tile_binding_new(program, c"acc", tile_binding_local, -1)
	accumulator.left = tile_unit_shaped_zero(64, 64)
	tile_node* add = tile_node_new(tile_assign)
	add.op = '+'
	add.left = tile_unit_reference(accumulator.binding)
	add.right = deep
	accumulator.next = add
	add.next = tile_unit_matrix_store(output, wide)
	program.body = accumulator
	tile_analyze(program)
	assert_equal(128, wide.rows)
	assert_equal(128, wide.cols)
	assert_equal(22528, program.shared_bytes)
	assert_equal(tile_dot_shared_bytes(64, 32, 64), program.shared_bytes)
	tile_lowering_plan* plan = tile_plan(program)
	assert_equal(22528, plan.shared_bytes)
	assert_equal(17408, tile_dot_shared_bytes(128, 16, 128))
	tile_dot_plan* first = tile_plan_dot(plan, deep)
	assert_equal(64, first.m_extent)
	assert_equal(32, first.k_extent)
	assert_equal(64, first.n_extent)
	assert_equal(1, first.fused)
	assert_equal(0, first.left.offset_bytes)
	assert_equal(192, first.left.row_stride)
	assert_equal(64 * 192, first.left.size_bytes)
	assert_equal(64 * 192, first.right.offset_bytes)
	assert_equal(320, first.right.row_stride)
	assert_equal(32 * 320, first.right.size_bytes)
	tile_dot_plan* second = tile_plan_dot(plan, wide)
	assert_equal(0, second.fused)
	assert_equal(16, second.k_extent)
	assert_equal(0, second.left.offset_bytes)
	assert_equal(64, second.left.row_stride)
	assert_equal(8192, second.right.offset_bytes)
	assert_equal(576, second.right.row_stride)
	assert_equal(16, second.left.alignment)
	assert_equal(4, second.right.element_stride)
	assert_equal(2, plan.dot_count)
	program.kernel_name = c"tile_rectangular_probe"
	int start = ptx_module_pos
	tile_ptx_emit(program)
	char* emitted = ptx_module_buf + start
	assert1(contains(emitted, c".shared .align 16 .b8 __tile_smem[22528];"))
	# Fragment rows are 16 shared rows apart; columns 16 elements apart.
	assert1(contains(emitted, c"st.shared.f32 [%taddr+8384], "))
	assert1(contains(emitted, c"st.shared.f32 [%taddr+3072], "))
	assert1(contains(emitted, c", [%tsb+17280];"))
