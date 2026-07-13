/*
TODO: push/pop edx: is it necessary?
*/

# Shared lowering for * / %: the var and float layers want the left
# operand popped into ebx, and so does imul; idiv/imod pop it off the
# machine stack themselves. % is integer-only. A struct-value operand
# dispatches to a user operator definition first
# (grammar/operator_overload.w).
int multiplicative_op(int type, int op):
	int left_type = binary1(type)
	int left_slot = stack_pos
	int right_type = promote(unary_expression())
	int overload_type = operator_overload_binary(left_type, right_type, op, left_slot)
	if (overload_type):
		return overload_type
	if (var_binary_operands(left_type, right_type)):
		if (op == '%'):
			error(c"var operands do not support %")
		pop_ebx()
		stack_pos = stack_pos - 1
		return var_binary_arithmetic(left_type, right_type, op)
	if (binary_float_kind(left_type, right_type)):
		if (op == '%'):
			error(c"float operands do not support %")
		pop_ebx()
		stack_pos = stack_pos - 1
		return float_binary_arithmetic(left_type, right_type, op)
	if (op == '*'):
		pop_ebx()
		alu_imul()
	else if (op == '/'):
		alu_idiv()
	else:
		alu_imod()
	stack_pos = stack_pos - 1
	return 3


int multiplicative_expr():
	int type = unary_expression()
	while (1):
		# A '*' on a fresh line starts a dereference statement, not a product
		if (peek(c"*") & (token_newline == 0)):
			get_token()
			type = multiplicative_op(type, '*')

		else if (accept(c"/")):
			type = multiplicative_op(type, '/')

		else if (accept(c"%")):
			type = multiplicative_op(type, '%')

		else:
			return type
