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
			binary1(type) /* pop %ebx ; add %ebx,%eax */
			type = binary2(multiplicative_expr(), 3, "\x5b\x01\xd8")

		else if (accept("-")):
			binary1(type) /* pop %ebx ; sub %eax,%ebx ; mov %ebx,%eax */
			type = binary2(multiplicative_expr(), 5, "\x5b\x29\xc3\x89\xd8")

		else:
			return type

