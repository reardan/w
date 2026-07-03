int multiplicative_expr();
/*
unary-operator
& * + - !

unary-expression
	postfix-expression
	unary-operator unary-expression

Unary operators bind tighter than any binary operator, so -a * b
means (-a) * b and unary operators can stack: !!a, -*p, *&x.
*/
int unary_expression():
	int type
	if (accept("&")):
		type = unary_expression()
		# eax already holds the lvalue address; that address is the value here
		return 3 /* constant */
	else if (accept("*")):
		type = unary_expression()
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
	else if (accept("!!")):
		# The tokenizer scans "!!" as one token; it booleanizes like !(!x)
		type = unary_expression()
		promote(type)
		/* test %eax,%eax ; setne %al ; movzbl %al,%eax */
		emit(8, "\x85\xc0\x0f\x95\xc0\x0f\xb6\xc0")
		return 3
	else if (accept("!")):
		type = unary_expression()
		promote(type)
		/* test %eax,%eax ; sete %al ; movzbl %al,%eax */
		emit(8, "\x85\xc0\x0f\x94\xc0\x0f\xb6\xc0")
		return 3
	else if (accept("-")):
		type = unary_expression()
		promote(type)
		neg_eax()
		return 3
	else if (accept("+")):
		# unary plus: load the operand's value, no code beyond the promote
		type = unary_expression()
		promote(type)
		return 3
	else if (accept("new")):
		# new type-name ( ) — allocates sizeof(type) and yields a type*
		int base = type_lookup(token)
		if (base < 0):
			print2("unknown type after new: '")
			print2(token)
			error("'")
		get_token()
		if (accept("(")):
			expect(")")

		# malloc(size), using the same callee-first stack layout as postfix calls
		sym_get_value("malloc")
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_int(type_get_size(base))
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_esp_plus(1 << word_size_log2)
		call_eax()
		be_pop(2)
		stack_pos = stack_pos - 2

		# eax holds the allocation's address as a plain value; the variable
		# it lands in carries the pointer type.
		return 3
	else:
		return postfix_expr()
