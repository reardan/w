# Fixed-layout tile lowering. This visitor only sees a complete, analyzed
# region. Its registers are independent of the streaming W evaluation stack.
int tile_ptx_register
int tile_ptx_label
int tile_ptx_shared
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
void tile_ptx_branch(int label, int conditional);

# Evaluate the seven addressing operands once, then form this lane's
# row/column address and bounds predicate. No invalid load is speculative.
int tile_ptx_matrix_address(tile_node* node):
	int[7] operands
	tile_node* arg = node.args
	for i in range(7):
		operands[i] = tile_ptx_expression(arg)
		arg = arg.next
	int row = operands[1]
	int col = operands[2]
	ptx_emit(c"add.s64 ")
	tile_ptx_reg(c"%ti", row)
	ptx_emit(c", ")
	tile_ptx_reg(c"%ti", row)
	ptx_line(c", %trow;")
	ptx_emit(c"add.s64 ")
	tile_ptx_reg(c"%ti", col)
	ptx_emit(c", ")
	tile_ptx_reg(c"%ti", col)
	ptx_line(c", %tcol;")
	ptx_emit(c"setp.ge.s64 %tm, ")
	tile_ptx_reg(c"%ti", row)
	ptx_line(c", 0;")
	ptx_emit(c"setp.ge.s64 %tp, ")
	tile_ptx_reg(c"%ti", col)
	ptx_line(c", 0;")
	ptx_line(c"and.pred %tm, %tm, %tp;")
	ptx_emit(c"setp.lt.s64 %tp, ")
	tile_ptx_reg(c"%ti", row)
	ptx_emit(c", ")
	tile_ptx_reg(c"%ti", operands[5])
	ptx_line(c";")
	ptx_line(c"and.pred %tm, %tm, %tp;")
	ptx_emit(c"setp.lt.s64 %tp, ")
	tile_ptx_reg(c"%ti", col)
	ptx_emit(c", ")
	tile_ptx_reg(c"%ti", operands[6])
	ptx_line(c";")
	ptx_line(c"and.pred %tm, %tm, %tp;")
	tile_ptx_binary_line(c"mul.lo.s64 ", row, row, operands[3], 0)
	tile_ptx_binary_line(c"mul.lo.s64 ", col, col, operands[4], 0)
	tile_ptx_binary_line(c"add.s64 ", row, row, col, 0)
	ptx_emit(c"shl.b64 ")
	tile_ptx_reg(c"%ti", row)
	ptx_emit(c", ")
	tile_ptx_reg(c"%ti", row)
	ptx_line(c", 2;")
	tile_ptx_binary_line(c"add.u64 ", operands[0], operands[0], row, 0)
	return operands[0]

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
	ptx_emit_int(tile_ptx_program.width)
	ptx_line(c";")
	ptx_line(c"and.pred %tm, %tm, %tp;")
	ptx_emit(c"shl.b64 ")
	tile_ptx_reg(c"%ti", index)
	ptx_emit(c", ")
	tile_ptx_reg(c"%ti", index)
	ptx_line(c", 2;")
	tile_ptx_binary_line(c"add.u64 ", base, base, index, 0)
	return base

int tile_ptx_dot(tile_node* node):
	int left = tile_ptx_expression(node.args)
	int right = tile_ptx_expression(node.args.next)
	int result = tile_ptx_temp()
	int shared = tile_ptx_shared
	tile_ptx_shared = shared + 1
	ptx_emit(c".shared .align 4 .b8 __tile_a")
	ptx_emit_int(shared)
	ptx_line(c"[1024];")
	ptx_emit(c".shared .align 4 .b8 __tile_b")
	ptx_emit_int(shared)
	ptx_line(c"[1024];")
	ptx_emit(c"mov.u64 %tsa, __tile_a")
	ptx_emit_int(shared)
	ptx_line(c";")
	ptx_line(c"cvta.shared.u64 %tsa, %tsa;")
	ptx_emit(c"mov.u64 %tsb, __tile_b")
	ptx_emit_int(shared)
	ptx_line(c";")
	ptx_line(c"cvta.shared.u64 %tsb, %tsb;")
	ptx_line(c"shl.b64 %tscratch, %ttid, 2;")
	ptx_line(c"add.u64 %taddr, %tsa, %tscratch;")
	ptx_emit(c"st.f32 [%taddr], ")
	tile_ptx_reg(c"%tf", left)
	ptx_line(c";")
	ptx_line(c"add.u64 %taddr, %tsb, %tscratch;")
	ptx_emit(c"st.f32 [%taddr], ")
	tile_ptx_reg(c"%tf", right)
	ptx_line(c";")
	ptx_barrier()
	ptx_emit(c"mov.f32 ")
	tile_ptx_reg(c"%tf", result)
	ptx_line(c", 0f00000000;")
	ptx_line(c"shl.b64 %tscratch, %trow, 6;")
	ptx_line(c"add.u64 %tsa, %tsa, %tscratch;")
	ptx_line(c"shl.b64 %tscratch, %tcol, 2;")
	ptx_line(c"add.u64 %tsb, %tsb, %tscratch;")
	for k in range(16):
		ptx_emit(c"ld.f32 %tfa, [%tsa+")
		ptx_emit_int(k * 4)
		ptx_line(c"];")
		ptx_emit(c"ld.f32 %tfb, [%tsb+")
		ptx_emit_int(k * 64)
		ptx_line(c"];")
		ptx_line(c"mul.rn.f32 %tfa, %tfa, %tfb;")
		ptx_emit(c"add.rn.f32 ")
		tile_ptx_reg(c"%tf", result)
		ptx_emit(c", ")
		tile_ptx_reg(c"%tf", result)
		ptx_line(c", %tfa;")
	ptx_barrier()
	return result

int tile_ptx_expression(tile_node* node):
	if (node.kind == tile_dot): return tile_ptx_dot(node)
	int result = tile_ptx_temp()
	if (node.kind == tile_literal):
		if (tile_ptx_float(node.type)):
			ptx_emit(c"mov.f32 ")
			tile_ptx_reg(c"%tf", result)
			ptx_emit(c", 0f")
			ptx_emit_hex32(node.value)
			ptx_line(c";")
		else: tile_ptx_integer(result, node.value)
	else if (node.kind == tile_reference):
		tile_ptx_copy(result, node.binding.storage_slot, tile_ptx_float(node.type))
	else if (node.kind == tile_program_id):
		ptx_emit(c"mov.u64 ")
		tile_ptx_reg(c"%ti", result)
		ptx_line(c", %tprogram;")
	else if (node.kind == tile_zero):
		ptx_emit(c"mov.f32 ")
		tile_ptx_reg(c"%tf", result)
		ptx_line(c", 0f00000000;")
	else if ((node.kind == tile_index) || (node.kind == tile_load)):
		int address
		if (node.kind == tile_index): address = tile_ptx_index_address(node)
		else: address = tile_ptx_matrix_address(node)
		ptx_emit(c"mov.f32 ")
		tile_ptx_reg(c"%tf", result)
		ptx_line(c", 0f00000000;")
		ptx_emit(c"@%tm ld.f32 ")
		tile_ptx_reg(c"%tf", result)
		ptx_emit(c", [")
		tile_ptx_reg(c"%ti", address)
		ptx_line(c"];")
	else if (node.kind == tile_unary):
		int value = tile_ptx_expression(node.left)
		int floating = tile_ptx_float(node.type)
		if (node.op == '+'): tile_ptx_copy(result, value, floating)
		else if (node.op == '!'):
			if (tile_ptx_float(node.left.type)):
				ptx_emit(c"setp.eq.f32 %tp, ")
				tile_ptx_reg(c"%tf", value)
				ptx_line(c", 0f00000000;")
			else:
				ptx_emit(c"setp.eq.s64 %tp, ")
				tile_ptx_reg(c"%ti", value)
				ptx_line(c", 0;")
			ptx_emit(c"selp.u64 ")
			tile_ptx_reg(c"%ti", result)
			ptx_line(c", 1, 0, %tp;")
		else:
			if (floating): ptx_emit(c"neg.f32 ")
			else: ptx_emit(c"neg.s64 ")
			char* prefix = c"%ti"
			if (floating): prefix = c"%tf"
			tile_ptx_reg(prefix, result)
			ptx_emit(c", ")
			tile_ptx_reg(prefix, value)
			ptx_line(c";")
	else if (node.kind == tile_binary):
		int left = tile_ptx_expression(node.left)
		int short_label = -1
		if ((node.op == tile_op_and) || (node.op == tile_op_or)):
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
		int floating = tile_ptx_float(node.left.type) || tile_ptx_float(node.right.type)
		if (floating):
			tile_ptx_float_convert(left, node.left.type)
			tile_ptx_float_convert(right, node.right.type)
		int op = node.op
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
		if (instruction != 0): tile_ptx_binary_line(instruction, result, left, right, floating)
		else:
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
		if (short_label >= 0): tile_ptx_label_emit(short_label)
	else: tile_error_at(node, c"internal error: unsupported analyzed tile expression")
	return result

void tile_ptx_label_emit(int label):
	ptx_emit(c"__tile_L")
	ptx_emit_int(label)
	ptx_line(c":")

void tile_ptx_branch(int label, int conditional):
	if (conditional): ptx_emit(c"@%tp ")
	ptx_emit(c"bra __tile_L")
	ptx_emit_int(label)
	ptx_line(c";")

void tile_ptx_statements(tile_node* node):
	while (node != 0):
		if (node.kind == tile_declare):
			int value = tile_ptx_expression(node.left)
			if (tile_ptx_float(node.binding.type)): tile_ptx_float_convert(value, node.left.type)
			tile_ptx_copy(node.binding.storage_slot, value, tile_ptx_float(node.binding.type))
		else if (node.kind == tile_assign):
			int value = tile_ptx_expression(node.right)
			if (node.left.kind == tile_reference):
				int dest = node.left.binding.storage_slot
				int floating = tile_ptx_float(node.left.type)
				if (floating): tile_ptx_float_convert(value, node.right.type)
				if (node.op != 0):
					char* instruction = c"add.s64 "
					if (node.op == '-'): instruction = c"sub.s64 "
					else if (node.op == '*'): instruction = c"mul.lo.s64 "
					if (floating):
						instruction = c"add.rn.f32 "
						if (node.op == '-'): instruction = c"sub.rn.f32 "
						else if (node.op == '*'): instruction = c"mul.rn.f32 "
					tile_ptx_binary_line(instruction, dest, dest, value, floating)
				else: tile_ptx_copy(dest, value, floating)
			else:
				tile_ptx_float_convert(value, node.right.type)
				int address = tile_ptx_index_address(node.left)
				if (node.op != 0):
					ptx_line(c"mov.f32 %tfa, 0f00000000;")
					ptx_emit(c"@%tm ld.f32 %tfa, [")
					tile_ptx_reg(c"%ti", address)
					ptx_line(c"];")
					if (node.op == '-'): ptx_emit(c"sub.rn.f32 ")
					else if (node.op == '*'): ptx_emit(c"mul.rn.f32 ")
					else: ptx_emit(c"add.rn.f32 ")
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
			tile_ptx_float_convert(value, arg.type)
			int address = tile_ptx_matrix_address(node)
			ptx_emit(c"@%tm st.f32 [")
			tile_ptx_reg(c"%ti", address)
			ptx_emit(c"], ")
			tile_ptx_reg(c"%tf", value)
			ptx_line(c";")
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
	tile_ptx_program = program
	tile_ptx_register = 0
	tile_ptx_label = 0
	tile_ptx_shared = 0
	ptx_kernel_begin(strclone(program.kernel_name))
	ptx_line(c".reg .b64 %tn, %ttid, %tlane, %tprogram, %tindex, %trow, %tcol;")
	ptx_line(c".reg .b64 %tsa, %tsb, %tscratch, %taddr;")
	ptx_line(c".reg .b32 %tid32, %tblock32;")
	ptx_line(c".reg .f32 %tfa, %tfb;")
	ptx_line(c".reg .pred %tp, %tm;")
	ptx_line(c"ld.param.u64 %tn, [p0];")
	ptx_line(c"mov.u32 %tid32, %tid.x;")
	ptx_line(c"cvt.u64.u32 %ttid, %tid32;")
	ptx_line(c"mov.u32 %tblock32, %ctaid.x;")
	ptx_line(c"cvt.u64.u32 %tprogram, %tblock32;")
	ptx_line(c"shr.u64 %trow, %ttid, 4;")
	ptx_line(c"and.b64 %tcol, %ttid, 15;")
	tile_binding* binding = program.bindings
	while (binding != 0):
		binding.storage_slot = tile_ptx_temp()
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
	for lane in range((program.width + 255) / 256):
		ptx_emit(c"add.u64 %tlane, %ttid, ")
		ptx_emit_int(lane * 256)
		ptx_line(c";")
		ptx_emit(c"mul.lo.u64 %tindex, %tprogram, ")
		ptx_emit_int(program.width)
		ptx_line(c";")
		ptx_line(c"add.u64 %tindex, %tindex, %tlane;")
		ptx_emit(c"mov.u64 ")
		tile_ptx_reg(c"%ti", program.tile_binding.storage_slot)
		ptx_line(c", %tindex;")
		tile_ptx_statements(program.body)
	ptx_line(c"ret;")
	ptx_kernel_end(program.capture_count, 0)
