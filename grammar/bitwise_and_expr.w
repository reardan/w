/*
 * bitwise-and-expr:
 *         equality-expr
 *         bitwise-and-expr & equality-expr
 */
int bitwise_and_expr():
	int type = equality_expr()
	while (accept(c"&")):
		int left_type = binary1(type)
		int right_type = equality_expr()
		if (var_binary_operands(left_type, right_type)):
			error(c"var operands do not support &")
		type = binary2_finish_pop(right_type)
		alu_and()

	return type

