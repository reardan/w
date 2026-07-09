/*
 * bitwise-or-expr:
 *         bitwise-xor-expr
 *         bitwise-or-expr | bitwise-xor-expr
 */
int bitwise_or_expr():
	int type = bitwise_xor_expr()
	while (accept(c"|")):
		int left_type = binary1(type)
		int right_type = bitwise_xor_expr()
		if (var_binary_operands(left_type, right_type)):
			error(c"var operands do not support |")
		type = binary2_finish_pop(right_type)
		alu_or()

	return type

