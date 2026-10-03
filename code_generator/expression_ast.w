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
