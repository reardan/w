/*
TODO: push/pop edx: is it necessary?
*/
int multiplicative_expr():
	int type = unary_expression()
	while (1):
		# A '*' on a fresh line starts a dereference statement, not a product
		if (peek("*") & (token_newline == 0)):
			get_token()
			binary1(type)
			type = binary2_finish_pop(unary_expression())
			alu_imul()

		else if (accept("/")):
			binary1(type)
			type = binary2_finish(unary_expression())
			alu_idiv()

		else if (accept("%")):
			binary1(type)
			type = binary2_finish(unary_expression())
			alu_imod()

		else:
			return type
