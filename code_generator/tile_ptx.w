# Tile lowering consumes an owned layout and staging plan for a complete,
# analyzed region. Registers are independent of the streaming W stack.
# A value occupies one register per element this thread holds: one for a
# scalar or a vector tile (per lane pass), and the plan's fragment count for
# a rank-two tile. Fragment registers are allocated consecutively.
int tile_ptx_register
int tile_ptx_label
tile_program* tile_ptx_program

void tile_ptx_reg(char* prefix, int reg):
	ptx_emit(prefix)
	ptx_emit_int(reg)

int tile_ptx_temp():
	int reg = tile_ptx_register
	tile_ptx_register = reg + 1
	ptx_emit(c".reg .b64 %ti")
	ptx_emit_int(reg)
	ptx_line(c";")
	ptx_emit(c".reg .f32 %tf")
	ptx_emit_int(reg)
	ptx_line(c";")
	return reg

int tile_ptx_temps(int count):
	int first = tile_ptx_temp()
	for i in range(1, count): tile_ptx_temp()
	return first

int tile_ptx_shape_count(int rank, int rows, int cols):
	if (rank != 2): return 1
	return tile_plan_fragments(tile_ptx_program.plan, rows, cols)

int tile_ptx_count(tile_node* node):
	return tile_ptx_shape_count(node.rank, node.rows, node.cols)

# Register of element f of a value; a scalar broadcasts to every element.
int tile_ptx_at(int base, int count, int f):
	if (count == 1): return base
	return base + f

int tile_ptx_float(int type):
	int real = type_unqualified(type)
	return real == float_type || real == float32_type

void tile_ptx_copy(int dest, int source, int floating):
	if (floating):
		ptx_emit(c"mov.f32 ")
		tile_ptx_reg(c"%tf", dest)
		ptx_emit(c", ")
		tile_ptx_reg(c"%tf", source)
	else:
		ptx_emit(c"mov.b64 ")
		tile_ptx_reg(c"%ti", dest)
		ptx_emit(c", ")
		tile_ptx_reg(c"%ti", source)
	ptx_line(c";")

void tile_ptx_float_convert(int reg, int type):
	if (tile_ptx_float(type)): return
	ptx_emit(c"cvt.rn.f32.s64 ")
	tile_ptx_reg(c"%tf", reg)
	ptx_emit(c", ")
	tile_ptx_reg(c"%ti", reg)
	ptx_line(c";")

void tile_ptx_integer(int reg, int value):
	ptx_emit(c"mov.s64 ")
	tile_ptx_reg(c"%ti", reg)
	ptx_emit(c", ")
	ptx_emit_int(value)
	ptx_line(c";")

void tile_ptx_binary_line(char* instruction, int dest, int left, int right, int floating):
	ptx_emit(instruction)
	char* prefix = c"%ti"
	if (floating): prefix = c"%tf"
	tile_ptx_reg(prefix, dest)
	ptx_emit(c", ")
	tile_ptx_reg(prefix, left)
	ptx_emit(c", ")
	tile_ptx_reg(prefix, right)
	ptx_line(c";")

int tile_ptx_expression(tile_node* node);
void tile_ptx_label_emit(int label);
void tile_ptx_binary_element(int op, int result, int left, int right, int floating);
void tile_ptx_branch(int label, int conditional);

void tile_ptx_immediate_line(char* instruction, int value):
	ptx_emit(instruction)
	ptx_emit_int(value)
	ptx_line(c";")

void tile_ptx_sync(tile_sync_point* point):
	assert1(point.scope == tile_sync_block)
	tile_ptx_immediate_line(c"bar.sync ", point.barrier_id)

void tile_ptx_reg_line(char* instruction, char* prefix, int reg, char* rest):
	ptx_emit(instruction)
	tile_ptx_reg(prefix, reg)
	ptx_line(rest)

# Evaluate the seven addressing operands once, then visit this thread's
# fragment: element (i, j) is row + trow + 16i, column + tcol + 16j. Each
# element has its own bounds predicate; no invalid access is speculative.
# A load writes `data` (zero-filled when masked); a store reads it.
void tile_ptx_matrix_access(tile_node* node, int rows, int cols, int data, int data_count, int store):
	tile_lowering_plan* plan = tile_ptx_program.plan
	int[7] operands
	tile_node* arg = node.args
	for i in range(7):
		operands[i] = tile_ptx_expression(arg)
		arg = arg.next
	int row = operands[1]
	int col = operands[2]
	ptx_emit(c"add.s64 ")
	tile_ptx_reg(c"%ti", row)
	tile_ptx_reg(c", %ti", row)
	ptx_line(c", %trow;")
	ptx_emit(c"add.s64 ")
	tile_ptx_reg(c"%ti", col)
	tile_ptx_reg(c", %ti", col)
	ptx_line(c", %tcol;")
	ptx_emit(c"mul.lo.s64 %tscratch, ")
	tile_ptx_reg(c"%ti", row)
	tile_ptx_reg(c", %ti", operands[3])
	ptx_line(c";")
	ptx_emit(c"mul.lo.s64 %taddr, ")
	tile_ptx_reg(c"%ti", col)
	tile_ptx_reg(c", %ti", operands[4])
	ptx_line(c";")
	ptx_line(c"add.s64 %tscratch, %tscratch, %taddr;")
	tile_ptx_immediate_line(c"shl.b64 %tscratch, %tscratch, ", plan.element_shift)
	ptx_emit(c"add.u64 %tmrow, ")
	tile_ptx_reg(c"%ti", operands[0])
	ptx_line(c", %tscratch;")
	# Byte steps between fragment rows and columns (16 logical elements).
	int step_shift = plan.element_shift + plan.row_shift
	for i in range(3, 5):
		ptx_emit(c"shl.b64 ")
		tile_ptx_reg(c"%ti", operands[i])
		tile_ptx_reg(c", %ti", operands[i])
		tile_ptx_immediate_line(c", ", step_shift)
	int row_blocks = rows / plan.matrix_rows
	int col_blocks = cols / plan.matrix_cols
	for i in range(row_blocks):
		if (i > 0):
			ptx_emit(c"add.u64 %tmrow, %tmrow, ")
			tile_ptx_reg(c"%ti", operands[3])
			ptx_line(c";")
			ptx_emit(c"add.s64 ")
			tile_ptx_reg(c"%ti", row)
			tile_ptx_reg(c", %ti", row)
			tile_ptx_immediate_line(c", ", plan.matrix_rows)
		tile_ptx_reg_line(c"setp.ge.s64 %tpr, ", c"%ti", row, c", 0;")
		ptx_emit(c"setp.lt.s64 %tp, ")
		tile_ptx_reg(c"%ti", row)
		tile_ptx_reg(c", %ti", operands[5])
		ptx_line(c";")
		ptx_line(c"and.pred %tpr, %tpr, %tp;")
		ptx_line(c"mov.u64 %taddr, %tmrow;")
		tile_ptx_reg_line(c"mov.u64 %tmcol, ", c"%ti", col, c";")
		for j in range(col_blocks):
			if (j > 0):
				ptx_emit(c"add.u64 %taddr, %taddr, ")
				tile_ptx_reg(c"%ti", operands[4])
				ptx_line(c";")
				tile_ptx_immediate_line(c"add.s64 %tmcol, %tmcol, ", plan.matrix_cols)
			ptx_line(c"setp.ge.s64 %tm, %tmcol, 0;")
			ptx_line(c"and.pred %tm, %tm, %tpr;")
			ptx_emit(c"setp.lt.s64 %tp, %tmcol, ")
			tile_ptx_reg(c"%ti", operands[6])
			ptx_line(c";")
			ptx_line(c"and.pred %tm, %tm, %tp;")
			int reg = tile_ptx_at(data, data_count, i * col_blocks + j)
			if (store):
				tile_ptx_reg_line(c"@%tm st.f32 [%taddr], ", c"%tf", reg, c";")
			else:
				tile_ptx_reg_line(c"mov.f32 ", c"%tf", reg, c", 0f00000000;")
				tile_ptx_reg_line(c"@%tm ld.f32 ", c"%tf", reg, c", [%taddr];")

int tile_ptx_index_address(tile_node* node):
	int base = tile_ptx_expression(node.left)
	int index = tile_ptx_expression(node.right)
	ptx_emit(c"setp.ge.s64 %tm, ")
	tile_ptx_reg(c"%ti", index)
	ptx_line(c", 0;")
	ptx_emit(c"setp.lt.s64 %tp, ")
	tile_ptx_reg(c"%ti", index)
	ptx_line(c", %tn;")
	ptx_line(c"and.pred %tm, %tm, %tp;")
	ptx_emit(c"setp.lt.u64 %tp, %tlane, ")
	ptx_emit_int(tile_ptx_program.plan.logical_width)
	ptx_line(c";")
	ptx_line(c"and.pred %tm, %tm, %tp;")
	ptx_emit(c"shl.b64 ")
	tile_ptx_reg(c"%ti", index)
	ptx_emit(c", ")
	tile_ptx_reg(c"%ti", index)
	tile_ptx_immediate_line(c", ", tile_ptx_program.plan.element_shift)
	tile_ptx_binary_line(c"add.u64 ", base, base, index, 0)
	return base

void tile_ptx_shared_line(char* instruction, char* address, int offset, int reg, int store):
	ptx_emit(instruction)
	if (store):
		ptx_emit(c"[")
		ptx_emit(address)
		ptx_emit(c"+")
		ptx_emit_int(offset)
		tile_ptx_reg(c"], %tf", reg)
	else:
		tile_ptx_reg(c"%tf", reg)
		ptx_emit(c", [")
		ptx_emit(address)
		ptx_emit(c"+")
		ptx_emit_int(offset)
		ptx_emit(c"]")
	ptx_line(c";")

# Stage one operand: this thread writes its fragment of a rows-by-cols tile
# into the shared buffer. %tsa/%tsb keep the per-thread row base for reads.
void tile_ptx_stage(tile_shared_buffer* buffer, int rows, int cols, int value, char* row_base):
	tile_lowering_plan* plan = tile_ptx_program.plan
	ptx_emit(c"mul.lo.u64 ")
	ptx_emit(row_base)
	ptx_emit(c", %trow, ")
	ptx_emit_int(buffer.row_stride)
	ptx_line(c";")
	ptx_emit(c"add.u64 ")
	ptx_emit(row_base)
	ptx_emit(c", ")
	ptx_emit(row_base)
	ptx_line(c", %tsmem;")
	ptx_emit(c"add.u64 %taddr, ")
	ptx_emit(row_base)
	ptx_line(c", %tscratch;")
	int col_blocks = cols / plan.matrix_cols
	for f in range(tile_plan_fragments(plan, rows, cols)):
		int offset = buffer.offset_bytes + (f / col_blocks) * plan.matrix_rows * buffer.row_stride + (f % col_blocks) * plan.matrix_cols * buffer.element_stride
		tile_ptx_shared_line(c"st.shared.f32 ", c"%taddr", offset, value + f, 1)

# A dot stages both operands, waits for the block, then forms an outer
# product per K step: this thread reads m/16 left and n/16 right values and
# accumulates (m/16)*(n/16) fused multiply-adds into its result fragment.
# The result starts at zero, or is an existing fragment (acc += dot(...)).
int tile_ptx_dot(tile_node* node, int accumulator):
	tile_lowering_plan* plan = tile_ptx_program.plan
	tile_dot_plan* dot = tile_plan_dot(plan, node)
	int left = tile_ptx_expression(node.args)
	int right = tile_ptx_expression(node.args.next)
	tile_ptx_immediate_line(c"shl.b64 %tscratch, %tcol, ", plan.element_shift)
	tile_ptx_stage(dot.left, dot.m_extent, dot.k_extent, left, c"%tsa")
	tile_ptx_stage(dot.right, dot.k_extent, dot.n_extent, right, c"%tsb")
	ptx_line(c"add.u64 %tsb, %tsmem, %tscratch;")
	tile_ptx_sync(dot.stage_ready)
	int row_blocks = dot.m_extent / plan.matrix_rows
	int col_blocks = dot.n_extent / plan.matrix_cols
	int result = accumulator
	if (result < 0):
		result = tile_ptx_temps(row_blocks * col_blocks)
		for f in range(row_blocks * col_blocks):
			tile_ptx_reg_line(c"mov.f32 ", c"%tf", result + f, c", 0f00000000;")
	int a = tile_ptx_temps(row_blocks)
	int b = tile_ptx_temps(col_blocks)
	for k in range(dot.k_extent):
		for i in range(row_blocks):
			int offset = dot.left.offset_bytes + i * plan.matrix_rows * dot.left.row_stride + k * dot.left.element_stride
			tile_ptx_shared_line(c"ld.shared.f32 ", c"%tsa", offset, a + i, 0)
		for j in range(col_blocks):
			int offset = dot.right.offset_bytes + k * dot.right.row_stride + j * plan.matrix_cols * dot.right.element_stride
			tile_ptx_shared_line(c"ld.shared.f32 ", c"%tsb", offset, b + j, 0)
		for i in range(row_blocks):
			for j in range(col_blocks):
				int reg = result + i * col_blocks + j
				ptx_emit(c"fma.rn.f32 ")
				tile_ptx_reg(c"%tf", reg)
				tile_ptx_reg(c", %tf", a + i)
				tile_ptx_reg(c", %tf", b + j)
				tile_ptx_reg(c", %tf", reg)
				ptx_line(c";")
	tile_ptx_sync(dot.reuse_ready)
	return result

int tile_ptx_expression(tile_node* node):
	if (node.kind == tile_dot): return tile_ptx_dot(node, -1)
	int count = tile_ptx_count(node)
	int result = tile_ptx_temps(count)
	if (node.kind == tile_literal):
		if (tile_ptx_float(node.type)):
			ptx_emit(c"mov.f32 ")
			tile_ptx_reg(c"%tf", result)
			ptx_emit(c", 0f")
			ptx_emit_hex32(node.value)
			ptx_line(c";")
		else: tile_ptx_integer(result, node.value)
	else if (node.kind == tile_reference):
		for f in range(count): tile_ptx_copy(result + f, node.binding.storage_slot + f, tile_ptx_float(node.type))
	else if (node.kind == tile_program_id):
		ptx_emit(c"mov.u64 ")
		tile_ptx_reg(c"%ti", result)
		ptx_line(c", %tprogram;")
	else if (node.kind == tile_zero):
		for f in range(count): tile_ptx_reg_line(c"mov.f32 ", c"%tf", result + f, c", 0f00000000;")
	else if (node.kind == tile_load):
		tile_ptx_matrix_access(node, node.rows, node.cols, result, count, 0)
	else if (node.kind == tile_index):
		int address = tile_ptx_index_address(node)
		tile_ptx_reg_line(c"mov.f32 ", c"%tf", result, c", 0f00000000;")
		ptx_emit(c"@%tm ld.f32 ")
		tile_ptx_reg(c"%tf", result)
		ptx_emit(c", [")
		tile_ptx_reg(c"%ti", address)
		ptx_line(c"];")
	else if (node.kind == tile_unary):
		int value = tile_ptx_expression(node.left)
		int floating = tile_ptx_float(node.type)
		for f in range(count):
			if (node.op == '+'): tile_ptx_copy(result + f, value + f, floating)
			else if (node.op == '!'):
				if (tile_ptx_float(node.left.type)):
					ptx_emit(c"setp.eq.f32 %tp, ")
					tile_ptx_reg(c"%tf", value + f)
					ptx_line(c", 0f00000000;")
				else:
					ptx_emit(c"setp.eq.s64 %tp, ")
					tile_ptx_reg(c"%ti", value + f)
					ptx_line(c", 0;")
				ptx_emit(c"selp.u64 ")
				tile_ptx_reg(c"%ti", result + f)
				ptx_line(c", 1, 0, %tp;")
			else:
				if (floating): ptx_emit(c"neg.f32 ")
				else: ptx_emit(c"neg.s64 ")
				char* prefix = c"%ti"
				if (floating): prefix = c"%tf"
				tile_ptx_reg(prefix, result + f)
				ptx_emit(c", ")
				tile_ptx_reg(prefix, value + f)
				ptx_line(c";")
	else if (node.kind == tile_binary):
		int left = tile_ptx_expression(node.left)
		int left_count = tile_ptx_count(node.left)
		int short_label = -1
		if ((node.op == tile_op_and) || (node.op == tile_op_or)):
			# Analysis restricts logical operators to uniform scalars.
			short_label = tile_ptx_label
			tile_ptx_label = short_label + 1
			int initial = 0
			if (node.op == tile_op_or): initial = 1
			tile_ptx_integer(result, initial)
			if (node.op == tile_op_and): ptx_emit(c"setp.eq.s64 %tp, ")
			else: ptx_emit(c"setp.ne.s64 %tp, ")
			tile_ptx_reg(c"%ti", left)
			ptx_line(c", 0;")
			tile_ptx_branch(short_label, 1)
		int right = tile_ptx_expression(node.right)
		int right_count = tile_ptx_count(node.right)
		int floating = tile_ptx_float(node.left.type) || tile_ptx_float(node.right.type)
		if (floating):
			for f in range(left_count): tile_ptx_float_convert(left + f, node.left.type)
			for f in range(right_count): tile_ptx_float_convert(right + f, node.right.type)
		for f in range(count):
			tile_ptx_binary_element(node.op, result + f, tile_ptx_at(left, left_count, f), tile_ptx_at(right, right_count, f), floating)
		if (short_label >= 0): tile_ptx_label_emit(short_label)
	else: tile_error_at(node, c"internal error: unsupported analyzed tile expression")
	return result

void tile_ptx_binary_element(int op, int result, int left, int right, int floating):
	char* instruction = 0
	if (op == '+'):
		instruction = c"add.s64 "
		if (floating): instruction = c"add.rn.f32 "
	else if (op == '-'):
		instruction = c"sub.s64 "
		if (floating): instruction = c"sub.rn.f32 "
	else if (op == '*'):
		instruction = c"mul.lo.s64 "
		if (floating): instruction = c"mul.rn.f32 "
	else if (op == '/'):
		instruction = c"div.s64 "
		if (floating): instruction = c"div.rn.f32 "
	else if (op == '%'): instruction = c"rem.s64 "
	if (instruction != 0):
		tile_ptx_binary_line(instruction, result, left, right, floating)
		return
	if ((op == tile_op_and) || (op == tile_op_or)):
		ptx_emit(c"setp.ne.s64 %tp, ")
		tile_ptx_reg(c"%ti", left)
		ptx_line(c", 0;")
		ptx_emit(c"setp.ne.s64 %tm, ")
		tile_ptx_reg(c"%ti", right)
		ptx_line(c", 0;")
		if (op == tile_op_and): ptx_line(c"and.pred %tp, %tp, %tm;")
		else: ptx_line(c"or.pred %tp, %tp, %tm;")
	else:
		ptx_emit(c"setp.")
		if (op == tile_op_eq): ptx_emit(c"eq")
		else if (op == tile_op_ne):
			if (floating): ptx_emit(c"neu")
			else: ptx_emit(c"ne")
		else if (op == tile_op_le): ptx_emit(c"le")
		else if (op == tile_op_ge): ptx_emit(c"ge")
		else if (op == '<'): ptx_emit(c"lt")
		else: ptx_emit(c"gt")
		char* prefix = c"%ti"
		if (floating):
			ptx_emit(c".f32 %tp, ")
			prefix = c"%tf"
		else: ptx_emit(c".s64 %tp, ")
		tile_ptx_reg(prefix, left)
		ptx_emit(c", ")
		tile_ptx_reg(prefix, right)
		ptx_line(c";")
	ptx_emit(c"selp.u64 ")
	tile_ptx_reg(c"%ti", result)
	ptx_line(c", 1, 0, %tp;")

void tile_ptx_label_emit(int label):
	ptx_emit(c"__tile_L")
	ptx_emit_int(label)
	ptx_line(c":")

void tile_ptx_branch(int label, int conditional):
	if (conditional): ptx_emit(c"@%tp ")
	ptx_emit(c"bra __tile_L")
	ptx_emit_int(label)
	ptx_line(c";")

char* tile_ptx_update_instruction(int op, int floating):
	if (floating):
		if (op == '-'): return c"sub.rn.f32 "
		if (op == '*'): return c"mul.rn.f32 "
		return c"add.rn.f32 "
	if (op == '-'): return c"sub.s64 "
	if (op == '*'): return c"mul.lo.s64 "
	return c"add.s64 "

void tile_ptx_assign_local(tile_node* node):
	tile_node* destination = node.left
	int dest = destination.binding.storage_slot
	if ((node.op == '+') && (node.right.kind == tile_dot)):
		if (tile_plan_dot(tile_ptx_program.plan, node.right).fused):
			tile_ptx_dot(node.right, dest)
			return
	int value = tile_ptx_expression(node.right)
	int value_count = tile_ptx_count(node.right)
	int floating = tile_ptx_float(destination.type)
	if (floating):
		for f in range(value_count): tile_ptx_float_convert(value + f, node.right.type)
	for f in range(tile_ptx_count(destination)):
		int source = tile_ptx_at(value, value_count, f)
		if (node.op != 0): tile_ptx_binary_line(tile_ptx_update_instruction(node.op, floating), dest + f, dest + f, source, floating)
		else: tile_ptx_copy(dest + f, source, floating)

void tile_ptx_statements(tile_node* node):
	while (node != 0):
		if (node.kind == tile_declare):
			int value = tile_ptx_expression(node.left)
			int count = tile_ptx_count(node.left)
			int floating = tile_ptx_float(node.binding.type)
			for f in range(count):
				if (floating): tile_ptx_float_convert(value + f, node.left.type)
				tile_ptx_copy(node.binding.storage_slot + f, value + f, floating)
		else if (node.kind == tile_assign):
			if (node.left.kind == tile_reference): tile_ptx_assign_local(node)
			else:
				int value = tile_ptx_expression(node.right)
				tile_ptx_float_convert(value, node.right.type)
				int address = tile_ptx_index_address(node.left)
				if (node.op != 0):
					ptx_line(c"mov.f32 %tfa, 0f00000000;")
					ptx_emit(c"@%tm ld.f32 %tfa, [")
					tile_ptx_reg(c"%ti", address)
					ptx_line(c"];")
					ptx_emit(tile_ptx_update_instruction(node.op, 1))
					tile_ptx_reg(c"%tf", value)
					ptx_emit(c", %tfa, ")
					tile_ptx_reg(c"%tf", value)
					ptx_line(c";")
				ptx_emit(c"@%tm st.f32 [")
				tile_ptx_reg(c"%ti", address)
				ptx_emit(c"], ")
				tile_ptx_reg(c"%tf", value)
				ptx_line(c";")
		else if (node.kind == tile_store):
			tile_node* arg = node.args
			for i in range(7): arg = arg.next
			int value = tile_ptx_expression(arg)
			int count = tile_ptx_count(arg)
			for f in range(count): tile_ptx_float_convert(value + f, arg.type)
			tile_ptx_matrix_access(node, arg.rows, arg.cols, value, count, 1)
		else if (node.kind == tile_if):
			int alternate = tile_ptx_label
			tile_ptx_label = alternate + 2
			int cond = tile_ptx_expression(node.left)
			ptx_emit(c"setp.eq.s64 %tp, ")
			tile_ptx_reg(c"%ti", cond)
			ptx_line(c", 0;")
			tile_ptx_branch(alternate, 1)
			tile_ptx_statements(node.body)
			tile_ptx_branch(alternate + 1, 0)
			tile_ptx_label_emit(alternate)
			tile_ptx_statements(node.otherwise)
			tile_ptx_label_emit(alternate + 1)
		else if (node.kind == tile_for):
			int start = tile_ptx_expression(node.left)
			int end = tile_ptx_expression(node.right)
			int dest = node.binding.storage_slot
			tile_ptx_copy(dest, start, 0)
			int begin = tile_ptx_label
			tile_ptx_label = begin + 2
			tile_ptx_label_emit(begin)
			ptx_emit(c"setp.ge.s64 %tp, ")
			tile_ptx_reg(c"%ti", dest)
			ptx_emit(c", ")
			tile_ptx_reg(c"%ti", end)
			ptx_line(c";")
			tile_ptx_branch(begin + 1, 1)
			tile_ptx_statements(node.body)
			ptx_emit(c"add.s64 ")
			tile_ptx_reg(c"%ti", dest)
			ptx_emit(c", ")
			tile_ptx_reg(c"%ti", dest)
			ptx_line(c", 1;")
			tile_ptx_branch(begin, 0)
			tile_ptx_label_emit(begin + 1)
		else: tile_error_at(node, c"internal error: unsupported analyzed tile statement")
		node = node.next

void tile_ptx_emit(tile_program* program):
	tile_lowering_plan* plan = tile_plan(program)
	tile_ptx_program = program
	tile_ptx_register = 0
	tile_ptx_label = 0
	ptx_kernel_begin(strclone(program.kernel_name))
	ptx_line(c".reg .b64 %tn, %ttid, %tlane, %tprogram, %tindex, %trow, %tcol;")
	ptx_line(c".reg .b64 %tsa, %tsb, %tsmem, %tscratch, %taddr, %tmrow, %tmcol;")
	ptx_line(c".reg .b32 %tid32, %tblock32;")
	ptx_line(c".reg .f32 %tfa, %tfb;")
	ptx_line(c".reg .pred %tp, %tm, %tpr;")
	if (plan.shared_bytes > 0):
		# One region serves every dot; see tile_dot_shared_bytes.
		ptx_emit(c".shared .align 16 .b8 __tile_smem[")
		ptx_emit_int(plan.shared_bytes)
		ptx_line(c"];")
		ptx_line(c"mov.u64 %tsmem, __tile_smem;")
	ptx_line(c"ld.param.u64 %tn, [p0];")
	ptx_line(c"mov.u32 %tid32, %tid.x;")
	ptx_line(c"cvt.u64.u32 %ttid, %tid32;")
	ptx_line(c"mov.u32 %tblock32, %ctaid.x;")
	ptx_line(c"cvt.u64.u32 %tprogram, %tblock32;")
	tile_ptx_immediate_line(c"shr.u64 %trow, %ttid, ", plan.row_shift)
	tile_ptx_immediate_line(c"and.b64 %tcol, %ttid, ", plan.col_mask)
	tile_binding* binding = program.bindings
	while (binding != 0):
		binding.storage_slot = tile_ptx_temps(tile_ptx_shape_count(binding.rank, binding.rows, binding.cols))
		if (binding.kind == tile_binding_capture):
			ptx_emit(c"ld.param.u64 ")
			tile_ptx_reg(c"%ti", binding.storage_slot)
			ptx_emit(c", [p")
			ptx_emit_int(binding.capture_slot)
			ptx_line(c"];")
			if (tile_ptx_float(binding.type)):
				ptx_emit(c"cvt.u32.u64 %tid32, ")
				tile_ptx_reg(c"%ti", binding.storage_slot)
				ptx_line(c";")
				ptx_emit(c"mov.b32 ")
				tile_ptx_reg(c"%tf", binding.storage_slot)
				ptx_line(c", %tid32;")
		binding = binding.next
	for lane in range(plan.lane_passes):
		ptx_emit(c"add.u64 %tlane, %ttid, ")
		ptx_emit_int(lane * plan.lane_stride)
		ptx_line(c";")
		ptx_emit(c"mul.lo.u64 %tindex, %tprogram, ")
		ptx_emit_int(plan.logical_width)
		ptx_line(c";")
		ptx_line(c"add.u64 %tindex, %tindex, %tlane;")
		ptx_emit(c"mov.u64 ")
		tile_ptx_reg(c"%ti", program.tile_binding.storage_slot)
		ptx_line(c", %tindex;")
		tile_ptx_statements(program.body)
	ptx_line(c"ret;")
	ptx_kernel_end(program.capture_count, 0)
