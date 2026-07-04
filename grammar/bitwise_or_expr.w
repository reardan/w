/*
 * bitwise-or-expr:
 *         bitwise-and-expr
 *         bitwise-and-expr | bitwise-or-expr
 */
int bitwise_or_expr():
	int type = bitwise_and_expr()
	while (accept(c"|")):
		binary1(type)
		type = binary2_finish_pop(bitwise_and_expr())
		alu_or()

	return type

