/*
 * additive-expr:
 *         multiplicative-expr
 *         additive-expr + multiplicative-expr
 *         additive-expr - multiplicative-expr
 */
int additive_expr():
	int type = multiplicative_expr()
	while (1):
		if (accept("+")):
			binary1(type)
			type = binary2_finish_pop(multiplicative_expr())
			alu_add()

		else if (accept("-")):
			binary1(type)
			type = binary2_finish_pop(multiplicative_expr())
			alu_sub()

		else:
			return type

