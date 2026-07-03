int multiplicative_expr();


# Store the constructor argument in eax into field field_index of the
# allocation whose address sits on top of the stack. Out-of-range
# indexes emit nothing; the caller warns about the argument count.
void new_store_field(int base_type, int field_index, int arg_type):
	if (field_index >= type_num_args(base_type)):
		return;
	int field_type = type_get_field_type_at(base_type, field_index)
	if (types_compatible(field_type, arg_type) == 0):
		warn_type_mismatch("constructor argument", field_type, arg_type)
	mov_ebx_esp()
	add_ebx_int32(type_get_field_offset_at(base_type, field_index))
	int field_size = type_get_size(field_type)
	if (field_size == 1):
		store_ebx_int8()
	else if (field_size == 2):
		store_ebx_int16()
	else if (field_size == 4):
		store_ebx_int32()
	else:
		store_ebx_word()


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
		alu_test_set(0x95) /* setne */
		return 3
	else if (accept("!")):
		type = unary_expression()
		promote(type)
		alu_test_set(0x94) /* sete */
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
		# new type-name — allocates sizeof(type) and yields a type*.
		# new type-name ( args ) also initializes the struct's fields from
		# the arguments in declaration order.
		int base = type_lookup(token)
		if (base < 0):
			print2("unknown type after new: '")
			print2(token)
			error("'")
		get_token()
		int has_parens = accept("(")

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

		if (has_parens):
			if (accept(")") == 0):
				# Constructor arguments: keep the allocation address on the
				# stack while each argument expression runs, storing every
				# result into its field.
				push_eax()
				stack_pos = stack_pos + 1
				int arg_type = expression()
				promote(arg_type)
				new_store_field(base, 0, arg_type)
				int field_index = 1
				while (accept(",")):
					arg_type = expression()
					promote(arg_type)
					new_store_field(base, field_index, arg_type)
					field_index = field_index + 1
				expect(")")
				if (field_index != type_num_args(base)):
					print_error("warning: new ")
					print_error(type_get_name(base))
					print_error(" expects ")
					print_error(itoa(type_num_args(base)))
					print_error(" arguments, got ")
					warning(itoa(field_index))
				pop_eax()
				stack_pos = stack_pos - 1

		# eax holds the allocation's address as a plain value; the variable
		# it lands in carries the pointer type.
		return 3
	else:
		return postfix_expr()
