/*
 * bitwise-and-expr:
 *         equality-expr
 *         bitwise-and-expr & equality-expr
 */
int bitwise_and_expr():
	int type = equality_expr()
	while (accept("&")):
		binary1(type) /* and %ebx,%eax */
		type = binary2_pop(equality_expr(), 2, "\x21\xd8")

	return type

