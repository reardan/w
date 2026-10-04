# Walk the completed, decoded scalar tree in source evaluation order.
# Reuse the production backend dispatch and stack accounting; the same
# peepholes, target word size and runtime division behavior still apply.
void emit_expression_ast(expression_ast* tree, int id):
	int op = tree.op[id]
	if ((op == 0) || (op == 'c')):
		mov_eax_int(tree.value[id])
		return
	if (op == 'f'):
		if (word_size == 8): mov_rax_int64_halves(tree.value[id], tree.high[id])
		else: mov_eax_int32(tree.value[id])
		return
	if ((op == 'v') || (op == 'C')):
		char* name = table + tree.value[id]
		strcpy(last_identifier, name)
		int sym = tree.symbol[id]
		sym_emit_value(sym, name)
		if (op == 'C'):
			int s = stack_pos
			push_slot()
			int arg = tree.left[id]
			int count = 0
			while (arg >= 0):
				emit_expression_ast(tree, arg)
				int got = promote(tree.result_type[arg])
				coerce_call_argument(sym_param_type(sym, count), got)
				push_call_argument_compact(got, 0)
				count = count + 1
				arg = tree.next_arg[arg]
			finish_call(4, s, count, sym, 0, load_int(table + sym + 6), count, 0, -1)
		return
	emit_expression_ast(tree, tree.left[id])
	int left_type = tree.result_type[tree.left[id]]
	if ((op == 'a') || (op == 'o')):
		promote(left_type)
		int h = be_ctrl_block()
		int child = tree.next_arg[tree.left[id]]
		while (child >= 0):
			if (op == 'a'): be_br_zero(h)
			else: be_br_nonzero(h)
			emit_expression_ast(tree, child)
			promote(tree.result_type[child])
			child = tree.next_arg[child]
		be_ctrl_end(h)
		alu_test_set(0x95)
		return
	if (op == 'K'):
		int got = promote(left_type)
		coerce_explicit(tree.value[id], got)
		return
	if (op == '?'):
		promote(left_type)
		int h_join = be_ctrl_block()
		int h_stub = be_ctrl_block()
		int h_else = be_ctrl_block()
		be_br_zero_discard(h_else)
		emit_expression_ast(tree, tree.right[id])
		int yt = promote(tree.result_type[tree.right[id]])
		be_br(h_stub)
		be_ctrl_end(h_else)
		emit_expression_ast(tree, tree.high[id])
		int nt = promote(tree.result_type[tree.high[id]])
		if (yt != 3): coerce(yt, nt)
		be_ctrl_end(h_stub)
		be_ctrl_end(h_join)
		return
	if (op == 'r'): return
	if (op == 'd'):
		promote(left_type)
		return
	if (op == '.'):
		if (tree.high[id]): promote(left_type)
		add_eax_int32(tree.value[id])
		return
	if ((op == 'n') || (op == 'p') || (op == '~') || (op == '!') || (op == 'b')):
		int kind = type_float_kind(promote(left_type))
		if (op == 'n'):
			if (kind == 1): xor_eax_int32(1 << 31)
			else if (kind == 2): btc_rax_63()
			else: neg_eax()
		if (op == '~'): not_eax()
		if (op == '!'): alu_test_set(0x94)
		if (op == 'b'): alu_test_set(0x95)
		return
	left_type = binary1(left_type)
	emit_expression_ast(tree, tree.right[id])
	int right_type = promote(tree.result_type[tree.right[id]])
	if ((op == 'L') || (op == 'R')):
		stack_pos = stack_pos - 1
		if (op == 'L'): alu_shl()
		else: alu_sar()
		return
	if ((op == '&') || (op == '|') || (op == '^')):
		pop_ebx_slot()
		if (op == '&'): alu_and()
		else if (op == '|'): alu_or()
		else: alu_xor()
		return
	if (op == 'i'):
		if (tree.value[id] > 1): imul_eax_int32(tree.value[id])
		pop_ebx()
		alu_add()
		stack_pos = stack_pos - 1
		return
	if (op >= 0x90):
		pop_ebx_slot()
		int cc = op
		int swap = 0
		if ((op == 0x9c) || (op == 0x9e)): swap = 1
		if ((op == 0x9c) || (op == 0x9f)): cc = 0x97
		if ((op == 0x9e) || (op == 0x9d)): cc = 0x93
		if (float_binary_compare(left_type, right_type, cc, swap) == 0): alu_cmp_set(op)
		return
	if (binary_float_kind(left_type, right_type)):
		pop_ebx_slot()
		float_binary_arithmetic(left_type, right_type, op)
		return
	if ((op == '+') || (op == '-') || (op == '*')):
		pop_ebx_slot()
		if (op == '+'): alu_add()
		else if (op == '-'): alu_sub()
		else: alu_imul()
	else:
		if (op == '/'): alu_idiv()
		else: alu_imod()
		stack_pos = stack_pos - 1
