/*
 * additive-expr:
 *         multiplicative-expr
 *         additive-expr + multiplicative-expr
 *         additive-expr - multiplicative-expr
 */
int additive_expr():
	int type = multiplicative_expr()
	while (1):
		if (accept(c"+")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(multiplicative_expr())
			int result_type = var_binary_arithmetic(left_type, right_type, '+')
			if (result_type == 0):
				result_type = float_binary_arithmetic(left_type, right_type, '+')
			if (result_type):
				type = result_type
			else:
				alu_add()
				type = 3

		else if (accept(c"-")):
			int left_type = binary1(type)
			int right_type = binary2_promote_pop(multiplicative_expr())
			int result_type = var_binary_arithmetic(left_type, right_type, '-')
			if (result_type == 0):
				result_type = float_binary_arithmetic(left_type, right_type, '-')
			if (result_type):
				type = result_type
			else:
				alu_sub()
				type = 3

		else:
			return type

