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
			binary1(type)  /* mov ebx, eax ; pop eax ; xor edx,edx ; idiv ebx */
			type = binary2(unary_expression(), 7, "\x89\xc3\x58\x31\xd2\xf7\xfb")

		else if (accept("%")):
			binary1(type) /* mov ebx, eax ; pop eax ; idiv ebx ; mov eax,edx */
			/* TODO: THIS NEEDS xor,edx,edx */
			type = binary2(unary_expression(), 9, "\x89\xc3\x58\x31\xd2\xf7\xfb\x89\xd0")

		else:
			return type
