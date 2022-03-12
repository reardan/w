/*
 * expression:
 *         bitwise-or-expr
 *         bitwise-or-expr = expression
 */
int expression():
	int type = bitwise_or_expr()
	if (accept("=")):
		be_push()
		stack_pos = stack_pos + 1
		int type2 = expression()
		if (verbosity >= 1):
			print2("expression() type: ")
			type_print(type)
			print_int("expression() type: ", type)
			print_int("expression() type2: ", type2)
		
		promote(type2)
		int type_size = type_get_size(type2)
		if (type == 1):
			emit(3, "\x5b\x88\x03") /* pop %ebx ; mov %al,(%ebx) */
		else if(type_size == 2):
			emit(4, "\x5b\x66\x89\x03") /* pop %ebx ; mov %ax,(%ebx) */
		else:
			emit(3, "\x5b\x89\x03") /* pop %ebx ; mov %eax,(%ebx) */
		stack_pos = stack_pos - 1
		type = 3  # no promotion
		# type = type2

	return type
