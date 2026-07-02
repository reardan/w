/*
TODO: push/pop edx: is it necessary?
*/
int multiplicative_expr():
	int type = unary_expression()
	while (1):
		if (accept("*")):
			binary1(type) /* imul eax,ebx */
			type = binary2_pop(unary_expression(), 3, "\x0f\xaf\xc3")

		else if (accept("/")):
			binary1(type)  /* mov ebx, eax ; pop eax ; cdq ; idiv ebx */
			type = binary2(unary_expression(), 6, "\x89\xc3\x58\x99\xf7\xfb")

		else if (accept("%")):
			binary1(type) /* mov ebx, eax ; pop eax ; cdq ; idiv ebx ; mov eax,edx */
			type = binary2(unary_expression(), 8, "\x89\xc3\x58\x99\xf7\xfb\x89\xd0")

		else:
			return type
