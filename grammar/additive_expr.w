/*
 * additive-expr:
 *         multiplicative-expr
 *         additive-expr + multiplicative-expr
 *         additive-expr - multiplicative-expr
 */

# Shared lowering for + and -: try the var layer, then the float layer,
# then fall back to the integer ALU.
int additive_op(int type, int op):
	int left_type = binary1(type)
	int right_type = binary2_promote_pop(multiplicative_expr())
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
