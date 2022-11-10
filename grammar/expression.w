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
		int type_size = type_get_size(type2)
		pop_ebx()
		if (type == 1):
			store_ebx_int8()
		else if(type_size == 2):
			store_ebx_int16()
		else:
			store_ebx_int32()

		stack_pos = stack_pos - 1

		type = 3  # no promotion
		# type = type2
		# assert(type == type2)
		# later: assert(convertable(type, type2))

	return type
