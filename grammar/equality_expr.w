/*
 * equality-expr:
 *         relational-expr
 *         equality-expr == relational-expr
 *         equality-expr != relational-expr
 */
int equality_expr():
	int type = relational_expr()
	while (1):
		if (accept("==")):
			binary1(type)
			type = binary2_finish_pop(relational_expr())
			alu_cmp_set(0x94) /* sete */

		else if (accept("!=")):
			binary1(type)
			type = binary2_finish_pop(relational_expr())
			alu_cmp_set(0x95) /* setne */

		else:
			return type

