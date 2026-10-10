# Lower owned main AST function syntax. No tokenizer, symbol lookup, source
# replay, or statement parser is reachable from this entry point.
int function_record_returns(function_node_ast* node):
	while (node != 0):
		if (node.kind == function_record_return): return 1
		if (node.kind == function_record_if):
			if (function_record_returns(node.body) && function_record_returns(node.otherwise)): return 1
		node = node.next
	return 0

void function_record_analyze(function_ast* recorded):
	function_body_ast* body = recorded.owned_body
	if (function_record_returns(body.statements) == 0):
		filename = body.source_file
		error(c"recorded scalar function requires a return on every path")
	body.analyzed = 1

int function_record_slot(function_body_ast* body, function_local_ast* binding, int base):
	if (binding.parameter): return binding.id - body.parameter_count - 1
	return base + binding.id + 1

void emit_function_record_expression(function_body_ast* body, function_node_ast* node, int base):
	if (node.kind == function_record_literal):
		mov_eax_int(node.value)
		return
	if (node.kind == function_record_reference):
		load_slot(function_record_slot(body, node.binding, base))
		return
	if (node.kind == function_record_unary):
		if (node.op == '-'):
			mov_eax_int(0)
			push_slot()
			emit_function_record_expression(body, node.left, base)
			pop_ebx_slot()
			alu_sub()
		else:
			emit_function_record_expression(body, node.left, base)
			if (node.op == '!'):
				push_slot()
				mov_eax_int(0)
				pop_ebx_slot()
				alu_cmp_set(0x94)
		return
	emit_function_record_expression(body, node.left, base)
	int op = node.op
	if ((op == function_record_and) || (op == function_record_or)):
		int done = be_ctrl_block()
		push_slot()
		mov_eax_int(0)
		pop_ebx_slot()
		alu_cmp_set(0x95)
		if (op == function_record_and): be_br_zero(done)
		else: be_br_nonzero(done)
		emit_function_record_expression(body, node.right, base)
		push_slot()
		mov_eax_int(0)
		pop_ebx_slot()
		alu_cmp_set(0x95)
		be_ctrl_end(done)
		return
	push_slot()
	emit_function_record_expression(body, node.right, base)
	if ((op == '/') || (op == '%')):
		if (op == '/'): alu_idiv()
		else: alu_imod()
		stack_pos = stack_pos - 1
		return
	pop_ebx_slot()
	if (op == '+'): alu_add()
	else if (op == '-'): alu_sub()
	else if (op == '*'): alu_imul()
	else if (op == '<'): alu_cmp_set(0x9c)
	else if (op == '>'): alu_cmp_set(0x9f)
	else if (op == function_record_le): alu_cmp_set(0x9e)
	else if (op == function_record_ge): alu_cmp_set(0x9d)
	else if (op == function_record_eq): alu_cmp_set(0x94)
	else: alu_cmp_set(0x95)

void emit_function_record_store(int slot):
	store_stack_var((stack_pos - slot) << word_size_log2)

void emit_function_record_statements(function_body_ast* body, function_node_ast* node, int base):
	while (node != 0):
		if ((node.kind == function_record_local) || (node.kind == function_record_assign)):
			int slot = function_record_slot(body, node.binding, base)
			if (node.op != 0):
				load_slot(slot)
				push_slot()
			emit_function_record_expression(body, node.left, base)
			if (node.op != 0):
				pop_ebx_slot()
				if (node.op == '+'): alu_add()
				else if (node.op == '-'): alu_sub()
				else: alu_imul()
			emit_function_record_store(slot)
		else if (node.kind == function_record_return):
			emit_function_record_expression(body, node.left, base)
			be_return(stack_pos)
		else if (node.kind == function_record_if):
			int done = be_ctrl_block()
			int alternate = be_ctrl_block()
			emit_function_record_expression(body, node.left, base)
			be_br_zero(alternate)
			emit_function_record_statements(body, node.body, base)
			be_br(done)
			be_ctrl_end(alternate)
			emit_function_record_statements(body, node.otherwise, base)
			be_ctrl_end(done)
		else:
			int slot = 0
			int bound = 0
			if (node.kind == function_record_for):
				slot = function_record_slot(body, node.binding, base)
				bound = base + node.value + 1
				emit_function_record_expression(body, node.left, base)
				emit_function_record_store(slot)
				emit_function_record_expression(body, node.right, base)
				emit_function_record_store(bound)
			int done = be_ctrl_block()
			int loop = be_ctrl_loop()
			if (node.kind == function_record_for):
				load_slot(slot)
				push_slot()
				load_slot(bound)
				pop_ebx_slot()
				alu_cmp_set(0x9c)
			else: emit_function_record_expression(body, node.left, base)
			be_br_zero(done)
			emit_function_record_statements(body, node.body, base)
			if (node.kind == function_record_for):
				load_slot(slot)
				push_slot()
				mov_eax_int(1)
				pop_ebx_slot()
				alu_add()
				emit_function_record_store(slot)
			be_br(loop)
			be_ctrl_end(loop)
			be_ctrl_end(done)
		node = node.next

# Stand-alone native W-ABI code. The caller may register this address in its
# own session. Until module relocation is implemented, this API is x86/x64.
int emit_recorded_scalar_function(function_ast* recorded):
	if (target_isa != 0): error(c"recorded scalar lowering currently requires x86 or x64")
	if (be_frame_active || ctrl_stack_pos || ers_count): error(c"recorded scalar lowering requires a function boundary")
	function_record_analyze(recorded)
	int outer_stack = stack_pos
	int outer_args = number_of_args
	int outer_dwarf_depth = dwarf_open_depth
	int start = codepos
	regalloc_function_end()
	be_notes_reset()
	stack_pos = 0
	number_of_args = recorded.argument_words
	# The code address has no module symbol yet. Suppress nested DWARF
	# notes instead of borrowing the preceding function's name and symbol.
	dwarf_open_depth = outer_dwarf_depth + 1
	be_function_prologue()
	int base = be_frame_words()
	stack_pos = base
	for i in range(recorded.owned_body.local_count):
		mov_eax_int(0)
		push_slot()
	emit_function_record_statements(recorded.owned_body, recorded.owned_body.statements, base)
	be_function_epilogue()
	dwarf_open_depth = outer_dwarf_depth
	stack_pos = outer_stack
	number_of_args = outer_args
	be_notes_reset()
	return start
