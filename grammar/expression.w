/*
 * expression:
 *         bitwise-or-expr
 *         bitwise-or-expr = expression
 */
int expression():
	int type = bitwise_or_expr()
	if (accept("=")):
		push_eax()
		stack_pos = stack_pos + 1
		int type2 = expression()
		if (verbosity >= 1):
			print2("expression() type: ")
			type_print(type)
			print_int("expression() type: ", type)
			print_int("expression() type2: ", type2)
		
		promote(type2)
		pop_ebx()

		# The store width comes from the left-hand side's type
		int lhs_size = word_size
		if ((type_get_pointer_level(type) == 0) & (type != 3) & (type != 4)):
			int declared_size = type_get_size(type)
			if (declared_size > 0):
				lhs_size = declared_size
		if (lhs_size == 1):
			store_ebx_int8()
		else if (lhs_size == 2):
			store_ebx_int16()
		else:
			store_ebx_int32()

		stack_pos = stack_pos - 1

		type = 3  # assignment yields the stored value
		# later: assert(convertable(type, type2))

	return type
