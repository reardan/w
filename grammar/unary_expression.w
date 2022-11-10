int multiplicative_expr();
/*
unary-operator
& * + - / !

unary-expression
	postfix-expression
	unary-operator multiplicative-expression
*/
int unary_expression():
	int type
	# untested:
	if (accept("&")):
		type = multiplicative_expr()
		char* type_name = type_get_name(type)
		int pointer_level = type_get_pointer_level(type)
		type = type_lookup_pointer(type_name, pointer_level + 1)
		if (type < 0):
			print_string0("type pointer not found during &: '", type_name)
			error("'")
		return type
	else if (accept("*")):
		type = multiplicative_expr()
		if (verbosity >= 1):
			print_error(itoa(line_number))
			print_error(": unary * type: ")
			print_error(itoa(type))
			print_error(", last symbol: ")
			print_error(last_global_declaration)
			print_error("\x0a")
		promote(type)
		return type
	# untested:
	else if (accept("!")):
		type = multiplicative_expr()
		promote(type)
		not_eax()
		return type
	else:
		return postfix_expr()
