/*
 * bitwise-and-expr:
 *         equality-expr
 *         bitwise-and-expr & equality-expr
 */
int bitwise_and_expr():
	int type = equality_expr()
	while (accept(c"&")):
		# Checked before binary1() promotes the left operand to a value
		int left_is_bool = operand_is_bool_lvalue(type)
		int left_type = binary1(type)
		int right_type = equality_expr()
		if (var_binary_operands(left_type, right_type)):
			error(c"var operands do not support &")
		if (condition_context & left_is_bool & operand_is_bool_lvalue(right_type)):
			warning(c"warning: bitwise '&' on bool operands in a condition does not short-circuit; did you mean '&&'?")
		type = binary2_finish_pop(right_type)
		alu_and()

	return type

