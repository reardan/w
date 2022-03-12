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
	# Integer literal
	if (int_literal()):
		type = 3

	# Identifier
	else if (identifier()) {
		type = 5
		new_type = sym_type(token)
		# TODO: fix int type (1)
		if (new_type != 1):
			type = new_type
	}
	# ( expression )
	else if (accept("(")) {
		type = expression()
		if (peek(")") == 0):
			error("No closing parenthesis")
	}
	# char literal
	else if ((token[0] == 39) & (token[1] != 0) &
					 (token[2] == 39) & (token[3] == 0)):
		emit(5, "\xb8....") /* mov $x,%eax */
		save_int(code + codepos - 4, token[1])
		type = 3

	else if (char_pointer_literal()):
		type = 3

	else:
		print2("Could not find a valid primary expression, token: ")
		error(token)

	get_token()
	return type
