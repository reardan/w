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
		type = 3 /* constant */
		type = 7 /* int32 */

	# Identifier
	else if (identifier()) {
		type = 2
		new_type = sym_type(token)
		# print_string0("found identifier '", token)
		# print2("', type: ")
		# type_print(new_type)
		int next_pointer_level = type_get_pointer_level(new_type) + 1
		# print_int("looking up next_pointer_level: ", next_pointer_level)
		int pointer_type = type_lookup_pointer(type_get_name(new_type), next_pointer_level)
		# print_int("found pointer_type: ", pointer_type)

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
	# char literal e.g. 'c'
	else if ((token[0] == 39) & (token[1] != 0) &
					 (token[2] == 39) & (token[3] == 0)):
		mov_eax_int(token[1])
		type = 3 /* TODO: migrate to type("char") */
		# type = 2

	else if (char_pointer_literal()):
		type = 3 /* TODO: migrate to type("char*") */
		# type = 17

	else:
		print2("Could not find a valid primary expression, token: ")
		error(token)

	get_token()
	return type
