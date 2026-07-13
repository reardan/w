/*
 * additive-expr:
 *         multiplicative-expr
 *         additive-expr + multiplicative-expr
 *         additive-expr - multiplicative-expr
 */

# Shared lowering for + and -: try the operator-overload layer, then
# the var layer, then the float layer, then fall back to the integer
# ALU.
int additive_op(int type, int op):
	int left_type = binary1(type)
	int left_slot = stack_pos
	int right_type = promote(multiplicative_expr())
	# A struct-value operand dispatches to a user operator definition
	# (grammar/operator_overload.w); it consumes the pushed left word
	# in place, so only take it into ebx on the ordinary path.
	int overload_type = operator_overload_binary(left_type, right_type, op, left_slot)
	if (overload_type):
		return overload_type
	pop_ebx()
	stack_pos = stack_pos - 1
	int result_type = var_binary_arithmetic(left_type, right_type, op)
	if (result_type == 0):
		result_type = float_binary_arithmetic(left_type, right_type, op)
	if (result_type):
		return result_type
	if (op == '+'):
		alu_add()
	else:
		alu_sub()
	return 3


int additive_expr():
	int type = multiplicative_expr()
	while (1):
		if (accept(c"+")):
			type = additive_op(type, '+')

		else if (accept(c"-")):
			type = additive_op(type, '-')

		else:
			return type
