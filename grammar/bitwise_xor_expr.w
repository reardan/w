/*
 * bitwise-xor-expr:
 *         bitwise-and-expr
 *         bitwise-xor-expr ^ bitwise-and-expr
 */
int bitwise_xor_expr():
	int type = bitwise_and_expr()
	while (accept(c"^")):
		int left_type = binary1(type)
		int right_type = bitwise_and_expr()
		if (var_binary_operands(left_type, right_type)):
			error(c"var operands do not support ^")
		type = binary2_finish_pop(right_type)
		alu_xor()

	return type
