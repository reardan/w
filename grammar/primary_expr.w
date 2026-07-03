int expression();

/*
 * primary-expr:
 *     identifier
 *     constant
 *     ( expression )
 */
int primary_expr():
	int type
	int new_type
	# Float literal (must run before int_literal, which only checks the first
	# character before decoding the whole token)
	int literal_type = float_literal()
	if (literal_type):
		type = literal_type

	# Bool literals
	else if (peek("true")):
		mov_eax_int(1)
		type = type_value(bool_type)

	else if (peek("false")):
		mov_eax_int(0)
		type = type_value(bool_type)

	# Integer literal
	else if (int_literal()):
		type = 3 /* constant */

	# Compile-time constant: the target's word size in bytes (4 or 8),
	# baked in when the enclosing file is compiled
	else if (peek("__word_size__")):
		mov_eax_int(word_size)
		type = 3 /* constant */

	# Identifier
	else if ((new_type = identifier()) >= 0) {
		type = new_type
	}
	# ( expression )
	else if (accept("(")) {
		type = expression()
		if (peek(")") == 0):
			error("No closing parenthesis")
	}
	# char literal e.g. 'c'
	else if ((token[0] == 39) & (token[1] != 0) &
					 (token[2] == 39) & (token[3] == 0)):
		mov_eax_int(token[1])
		type = 3 /* constant */

	# escaped char literal e.g. '\n'
	else if ((token[0] == 39) & (token[1] == 92) &
					 (token[3] == 39) & (token[4] == 0)):
		int c = token[2]
		if (c == 'n'):
			c = 10
		else if (c == 't'):
			c = 9
		else if (c == 'r'):
			c = 13
		else if (c == '0'):
			c = 0
		mov_eax_int(c)
		type = 3 /* constant */

	else if (char_pointer_literal()):
		type = 3 /* constant: eax already holds the string address */

	else:
		print2("Could not find a valid primary expression, token: ")
		error(token)

	get_token()
	return type
