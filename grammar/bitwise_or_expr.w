/*
 * bitwise-or-expr:
 *         bitwise-and-expr
 *         bitwise-and-expr | bitwise-or-expr
 */
int bitwise_or_expr():
	int type = bitwise_and_expr()
	while (accept("|")):
		binary1(type) /* or %ebx,%eax */
		type = binary2_pop(bitwise_and_expr(), 2, "\x09\xd8")

	return type

