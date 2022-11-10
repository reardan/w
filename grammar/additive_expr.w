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
			binary1(type) /* add %ebx,%eax */
			type = binary2_pop(multiplicative_expr(), 2, "\x01\xd8")

		else if (accept("-")):
			binary1(type) /* sub %eax,%ebx ; mov %ebx,%eax */
			type = binary2_pop(multiplicative_expr(), 4, "\x29\xc3\x89\xd8")

		else:
			return type

