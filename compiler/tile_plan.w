# The initial planner spells out the existing 256-thread, row-major layout.
# Each syntactic dot owns two disjoint shared buffers for its entire lifetime.
# Loop iterations reuse those assignments only after the reuse barrier; no
# buffer reuse between distinct dots or branches is attempted here.
import compiler.tile_ast


int tile_plan_element(tile_lowering_plan* plan, int thread, int pass):
	return thread + pass * plan.lane_stride


int tile_plan_thread(tile_lowering_plan* plan, int element):
	return element % plan.threads


int tile_plan_pass(tile_lowering_plan* plan, int element):
	return element / plan.lane_stride


int tile_plan_row(tile_lowering_plan* plan, int thread):
	return thread >> plan.row_shift


int tile_plan_col(tile_lowering_plan* plan, int thread):
	return thread & plan.col_mask


tile_dot_plan* tile_plan_dot(tile_lowering_plan* plan, tile_node* node):
	tile_dot_plan* dot = plan.dots
	while (dot != 0):
		if (dot.node == node): return dot
		dot = dot.next
	return 0


tile_shared_buffer* tile_plan_buffer(tile_lowering_plan* plan, int id):
	tile_shared_buffer* buffer = cast(tile_shared_buffer*, tile_owned_zero(sizeof(tile_shared_buffer)))
	buffer.id = id
	buffer.offset_bytes = plan.shared_bytes
	buffer.size_bytes = plan.matrix_rows * plan.matrix_cols << plan.element_shift
	buffer.alignment = 1 << plan.element_shift
	buffer.element_stride = 1 << plan.element_shift
	buffer.row_stride = plan.matrix_cols << plan.element_shift
	plan.shared_bytes = plan.shared_bytes + buffer.size_bytes
	return buffer


tile_sync_point* tile_plan_sync(int phase):
	tile_sync_point* sync = cast(tile_sync_point*, tile_owned_zero(sizeof(tile_sync_point)))
	sync.phase = phase
	sync.barrier_id = 0
	sync.scope = tile_sync_block
	return sync


void tile_plan_expression(tile_lowering_plan* plan, tile_node* node):
	if (node == 0): return
	tile_plan_expression(plan, node.left)
	tile_plan_expression(plan, node.right)
	tile_node* arg = node.args
	while (arg != 0):
		tile_plan_expression(plan, arg)
		arg = arg.next
	if (node.kind != tile_dot): return
	# Children stage first, so IDs follow evaluation order, including nested
	# dots. The consumer looks up node identity rather than counting emits.
	tile_dot_plan* dot = cast(tile_dot_plan*, tile_owned_zero(sizeof(tile_dot_plan)))
	dot.node = node
	dot.id = plan.dot_count
	plan.dot_count = plan.dot_count + 1
	dot.left = tile_plan_buffer(plan, dot.id * 2)
	dot.right = tile_plan_buffer(plan, dot.id * 2 + 1)
	dot.k_extent = node.args.cols
	dot.stage_thread_shift = plan.element_shift
	dot.row_shift = plan.row_shift + plan.element_shift
	dot.col_shift = plan.element_shift
	dot.stage_ready = tile_plan_sync(tile_sync_stage_ready)
	dot.reuse_ready = tile_plan_sync(tile_sync_reuse_ready)
	if (plan.dots_tail == 0): plan.dots = dot
	else: plan.dots_tail.next = dot
	plan.dots_tail = dot


void tile_plan_statements(tile_lowering_plan* plan, tile_node* node):
	while (node != 0):
		if (node.kind == tile_store):
			# A store evaluates its value before its seven address operands.
			tile_node* value = node.args
			while (value.next != 0): value = value.next
			tile_plan_expression(plan, value)
			tile_node* arg = node.args
			while (arg != value):
				tile_plan_expression(plan, arg)
				arg = arg.next
		else if (node.kind == tile_assign):
			tile_plan_expression(plan, node.right)
			tile_plan_expression(plan, node.left)
		else:
			tile_plan_expression(plan, node.left)
			tile_plan_expression(plan, node.right)
		tile_plan_statements(plan, node.body)
		tile_plan_statements(plan, node.otherwise)
		node = node.next


tile_lowering_plan* tile_plan(tile_program* program):
	assert1(program.analyzed)
	if ((program.plan != 0) && (program.plan_generation == retained_arena_generation)): return program.plan
	tile_lowering_plan* plan = cast(tile_lowering_plan*, tile_owned_zero(sizeof(tile_lowering_plan)))
	plan.threads = 256
	plan.logical_width = program.width
	plan.lane_passes = (program.width + plan.threads - 1) / plan.threads
	plan.lane_stride = plan.threads
	plan.matrix_rows = 16
	plan.matrix_cols = 16
	plan.row_shift = 4
	plan.col_mask = plan.matrix_cols - 1
	plan.element_shift = 2
	tile_plan_statements(plan, program.body)
	assert1(plan.shared_bytes == program.shared_bytes)
	program.plan = plan
	program.plan_generation = retained_arena_generation
	return plan
