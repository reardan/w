/*
TODO: push/pop edx: is it necessary?
*/
int multiplicative_expr():
	int type = unary_expression()
	while (1):
		# A '*' on a fresh line starts a dereference statement, not a product
		if (peek("*") & (token_newline == 0)):
			get_token()
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(unary_expression())
			int result_type = float_binary_arithmetic(left_type, right_type, '*')
			if (result_type):
				type = result_type
			else:
				alu_imul()
				type = 3

		else if (accept("/")):
			int left_type = binary1(type)
			int right_type = promote(unary_expression())
			if (binary_float_kind(left_type, right_type)):
				pop_ebx()
				stack_pos = stack_pos - 1
				int result_type = float_binary_arithmetic(left_type, right_type, '/')
				type = result_type
			else:
				alu_idiv()
				stack_pos = stack_pos - 1
				type = 3

		else if (accept("%")):
			int left_type = binary1(type)
			int right_type = promote(unary_expression())
			if (binary_float_kind(left_type, right_type)):
				error("float operands do not support %")
			alu_imod()
			stack_pos = stack_pos - 1
			type = 3

		else:
			return type
