# Walk the completed, decoded integer tree in source evaluation order.
# Reuse the production backend dispatch and stack accounting; the same
# peepholes, target word size and runtime division behavior still apply.
void emit_expression_ast(expression_ast* tree, int id):
	int op = tree.op[id]
	if ((op == 0) || (op == 'c')):
		mov_eax_int(tree.value[id])
		return
	if (op == 'v'):
		char* name = table + tree.value[id]
		strcpy(last_identifier, name)
		sym_emit_value(tree.symbol[id], name)
		return
	emit_expression_ast(tree, tree.left[id])
	int left_type = tree.result_type[tree.left[id]]
	if ((op == 'n') || (op == 'p') || (op == '~') || (op == '!') || (op == 'b')):
		promote(left_type)
		if (op == 'n'): neg_eax()
		if (op == '~'): not_eax()
		if (op == '!'): alu_test_set(0x94)
		if (op == 'b'): alu_test_set(0x95)
		return
	binary1(left_type)
	emit_expression_ast(tree, tree.right[id])
	promote(tree.result_type[tree.right[id]])
	if ((op == '+') || (op == '-') || (op == '*')):
		pop_ebx_slot()
		if (op == '+'): alu_add()
		else if (op == '-'): alu_sub()
		else: alu_imul()
	else:
		if (op == '/'): alu_idiv()
		else: alu_imod()
		stack_pos = stack_pos - 1
