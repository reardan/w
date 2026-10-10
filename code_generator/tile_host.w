# Host lowering runs only after the entire tile region has been recorded
# and analyzed. The header is a pure integer tree with owned capture names.

void tile_host_expression(tile_node* node):
	if (node.kind == tile_literal):
		mov_eax_int(node.value)
		return
	if (node.kind == tile_reference):
		promote(sym_get_value(node.binding.name))
		return
	if (node.kind == tile_unary):
		if (node.op == '-'):
			mov_eax_int(0)
			push_slot()
			tile_host_expression(node.left)
			pop_ebx_slot()
			alu_sub()
		else:
			tile_host_expression(node.left)
			if (node.op == '!'):
				push_slot()
				mov_eax_int(0)
				pop_ebx_slot()
				alu_cmp_set(0x94)
		return
	if (node.kind == tile_binary):
		tile_host_expression(node.left)
		if ((node.op == tile_op_and) || (node.op == tile_op_or)):
			int done = be_ctrl_block()
			# Normalize the left operand before the short-circuit branch.
			push_slot()
			mov_eax_int(0)
			pop_ebx_slot()
			alu_cmp_set(0x95)
			if (node.op == tile_op_and): be_br_zero(done)
			else: be_br_nonzero(done)
			tile_host_expression(node.right)
			push_slot()
			mov_eax_int(0)
			pop_ebx_slot()
			alu_cmp_set(0x95)
			be_ctrl_end(done)
			return
		push_slot()
		tile_host_expression(node.right)
		# Division helpers consume the parked left operand themselves.
		if ((node.op == '/') || (node.op == '%')):
			if (node.op == '/'): alu_idiv()
			else: alu_imod()
			stack_pos = stack_pos - 1
			return
		pop_ebx_slot()
		if (node.op == '+'): alu_add()
		else if (node.op == '-'): alu_sub()
		else if (node.op == '*'): alu_imul()
		else if (node.op == '<'): alu_cmp_set(0x9c)
		else if (node.op == '>'): alu_cmp_set(0x9f)
		else if (node.op == tile_op_le): alu_cmp_set(0x9e)
		else if (node.op == tile_op_ge): alu_cmp_set(0x9d)
		else if (node.op == tile_op_eq): alu_cmp_set(0x94)
		else if (node.op == tile_op_ne): alu_cmp_set(0x95)
		return
	# Analysis rejects every other header form before any emission.
	assert1(0) # coverage: exempt analyzed header invariant


void tile_emit_program(tile_program* program):
	tile_ptx_emit(program)
	int base = stack_pos
	tile_host_expression(program.bound)
	push_slot()
	tile_binding* binding = program.bindings
	while (binding != 0):
		if (binding.kind == tile_binding_capture):
			promote(sym_get_value(binding.name))
			push_slot()
		binding = binding.next
	sym_get_value(c"__w_gpu_launch_tiles")
	push_slot()
	be_emit_inline_cstr(strlen(program.kernel_name), program.kernel_name)
	push_slot()
	load_slot(base + 1)
	push_slot()
	mov_eax_int(program.width)
	push_slot()
	lea_eax_esp_plus((stack_pos - (base + program.capture_count)) << word_size_log2)
	push_slot()
	mov_eax_int(program.capture_count)
	push_slot()
	mov_eax_esp_plus(5 << word_size_log2)
	call_eax()
	pop_to(base)
