# The planner spells out the 256-thread layout. Vector tiles map element
# thread + pass*256 to a thread. Rank-two tiles of any supported shape use a
# 16-by-16 thread grid; thread (r, c) holds the strided fragment of elements
# (r + 16i, c + 16j), so neighbouring threads touch neighbouring columns
# (coalesced global access) and every operand of a dot shares one layout.
# All dots reuse a single shared region; see tile_dot_shared_bytes.
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


int tile_plan_fragments(tile_lowering_plan* plan, int rows, int cols):
	return (rows / plan.matrix_rows) * (cols / plan.matrix_cols)


# Logical row and column of fragment element f held by a thread.
int tile_plan_fragment_row(tile_lowering_plan* plan, int thread, int cols, int f):
	return tile_plan_row(plan, thread) + plan.matrix_rows * (f / (cols / plan.matrix_cols))


int tile_plan_fragment_col(tile_lowering_plan* plan, int thread, int cols, int f):
	return tile_plan_col(plan, thread) + plan.matrix_cols * (f % (cols / plan.matrix_cols))


tile_dot_plan* tile_plan_dot(tile_lowering_plan* plan, tile_node* node):
	tile_dot_plan* dot = plan.dots
	while (dot != 0):
		if (dot.node == node): return dot
		dot = dot.next
	return 0


tile_shared_buffer* tile_plan_buffer(tile_lowering_plan* plan, int id, int offset, int rows, int cols):
	tile_shared_buffer* buffer = cast(tile_shared_buffer*, tile_owned_zero(sizeof(tile_shared_buffer)))
	buffer.id = id
	buffer.offset_bytes = offset
	buffer.row_stride = tile_shared_row_words(cols) << plan.element_shift
	buffer.size_bytes = rows * buffer.row_stride
	buffer.alignment = 16
	buffer.element_stride = 1 << plan.element_shift
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
	tile_node* left = node.args
	tile_node* right = left.next
	dot.m_extent = left.rows
	dot.k_extent = left.cols
	dot.n_extent = right.cols
	dot.left = tile_plan_buffer(plan, dot.id * 2, 0, left.rows, left.cols)
	dot.right = tile_plan_buffer(plan, dot.id * 2 + 1, dot.left.size_bytes, right.rows, right.cols)
	int bytes = dot.right.offset_bytes + dot.right.size_bytes
	if (bytes > plan.shared_bytes): plan.shared_bytes = bytes
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
			# acc += dot(a, b) accumulates straight into the local's fragment.
			if ((node.op == '+') && (node.right.kind == tile_dot) && (node.left.kind == tile_reference)):
				tile_plan_dot(plan, node.right).fused = 1
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
