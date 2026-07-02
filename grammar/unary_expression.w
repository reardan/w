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
	if (accept("&")):
		type = multiplicative_expr()
		# eax already holds the lvalue address; that address is the value here
		return 3 /* constant */
	else if (accept("*")):
		type = multiplicative_expr()
		if (verbosity >= 1):
			print_error(itoa(line_number))
			print_error(": unary * type: ")
			print_error(itoa(type))
			print_error(", last symbol: ")
			print_error(last_global_declaration)
			print_error("\x0a")
		promote(type) /* load the pointer; eax becomes the element's address */
		if (type_get_pointer_level(type) > 0):
			return type_lookup_previous_pointer(type)
		return 1 /* deref of a plain int: word-sized lvalue */
	else if (accept("!")):
		type = multiplicative_expr()
		promote(type)
		/* test %eax,%eax ; sete %al ; movzbl %al,%eax */
		emit(8, "\x85\xc0\x0f\x94\xc0\x0f\xb6\xc0")
		return 3
	else if (accept("-")):
		type = multiplicative_expr()
		promote(type)
		neg_eax()
		return 3
	else:
		return postfix_expr()
