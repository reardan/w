/*
postfix-expr:
	primary-expr
	postfix-expr [ expression ]
	postfix-expr ( expression-list-opt )
	postfix-expr . identifier

 */
int postfix_expr():
	# print_string("postfix_expr: ", token)
	int type = primary_expr()
	if (accept("[")):
		binary1(type)
		/* pop %ebx ; add %ebx,%eax */
		binary2(expression(), 3, "\x5b\x01\xd8")
		/* TODO: pop ebx; mul ebx,{1,4,8,type_size,...}; add eax,ebx */
		expect("]")
		type = 1  # promote to char
	
	else if (accept("(")):
		int s = stack_pos
		push_eax()
		stack_pos = stack_pos + 1
		if (accept(")") == 0):
			int arg_type = expression()
			if (pointer_indirection == 0):
				promote(arg_type)
			push_eax()
			stack_pos = stack_pos + 1
			while (accept(",")):
				int arg_type = expression()
				if (pointer_indirection == 0):
					promote(arg_type)
				push_eax()
				stack_pos = stack_pos + 1

			expect(")")

		# emit(7, "\x8b\x84\x24....") /* mov (n * 4)(%esp),%eax */
		# save_int(code + codepos - 4, (stack_pos - s - 1) << word_size_log2)
		mov_eax_esp_plus((stack_pos - s - 1) << word_size_log2)

		if (type_lookup_pointer(type) > 0):
			warning("type_lookup_pointer > 0")
			promote_eax()
		emit(2, "\xff\xd0") /* call *%eax */
		be_pop(stack_pos - s)
		stack_pos = s
		type = 3  # dont promote

	else if (accept(".")):
		# For structures, find offset of field name
		int num_args = type_num_args(type)
		if (num_args > 0):
			int arg = type_get_arg(type, token)
			if(arg < 0):
				print2("struct field '")
				print2(token)
				error("' not found")
			# Return right side field type instead of struct
			emit(5, "\x05....") /* \x2d add eax,... */
			/* \x2d: sub eax, ... WRONG use sub instead? */
			int stack_offset = type_get_field_offset(type, token)
			save_int(code + codepos - 4, stack_offset)

			# use child type:
			type = type_get_field_type(type, token)
			if (type < 0):
				print_int0("child field not found: '", type)
				error("")
			if (verbosity >= 1):
				print2(itoa(line_number))
				print_string0(": using child type: ", type_get_name(type))
				print_int(": ", type)

		get_token()
		/*while (accept(".")):
			println2("accepted '.'")
			print_string("token: ", token)
			get_token()*/

	return type
