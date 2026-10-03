# Walk the completed, decoded integer tree in source evaluation order.
# Reuse the production backend dispatch and stack accounting; the same
# peepholes, target word size and runtime division behavior still apply.
void emit_expression_ast(expression_ast* tree, int id):
	int op = tree.op[id]
	if (op == 0):
		mov_eax_int(tree.value[id])
		return
	emit_expression_ast(tree, tree.left[id])
	if ((op == 'n') || (op == 'p')):
		promote(3)
		if (op == 'n'): neg_eax()
		return
	binary1(3)
	emit_expression_ast(tree, tree.right[id])
	promote(3)
	if ((op == '+') || (op == '-') || (op == '*')):
		pop_ebx_slot()
		if (op == '+'): alu_add()
		else if (op == '-'): alu_sub()
		else: alu_imul()
	else:
		if (op == '/'): alu_idiv()
		else: alu_imod()
		stack_pos = stack_pos - 1
