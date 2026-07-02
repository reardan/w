/*
postfix-expr:
	primary-expr
	postfix-expr [ expression ]
	postfix-expr ( expression-list-opt )
	postfix-expr . identifier

 */
int postfix_expr():
	int type = primary_expr()
	while (1):
		if (accept("[")):
			binary1(type) /* load the base pointer and push it */
			# The element type drives both index scaling and the load width
			int element_type = 2 /* char: byte elements by default */
			if (type_get_pointer_level(type) > 0):
				int previous_type = type_lookup_previous_pointer(type)
				if (previous_type >= 0):
					element_type = previous_type
			int element_size = type_get_size(element_type)
			promote(expression())
			if (element_size > 1):
				imul_eax_int32(element_size)
			pop_ebx()
			emit(2, "\x01\xd8") /* add %ebx,%eax */
			stack_pos = stack_pos - 1
			expect("]")
			type = element_type

		else if (accept("(")):
			# Remember the callee's declared arity now; parsing the arguments
			# below overwrites last_identifier.
			int expected_args = -1
			char* callee_name = 0
			if (type == 4):
				int callee = sym_lookup(last_identifier)
				if (callee >= 0):
					expected_args = sym_num_args(callee)
					if (expected_args >= 0):
						callee_name = strclone(last_identifier)

			int s = stack_pos
			push_eax()
			stack_pos = stack_pos + 1
			int passed_args = 0
			if (accept(")") == 0):
				promote(expression())
				push_eax()
				stack_pos = stack_pos + 1
				passed_args = 1
				while (accept(",")):
					promote(expression())
					push_eax()
					stack_pos = stack_pos + 1
					passed_args = passed_args + 1

				expect(")")

			if (expected_args >= 0):
				if (passed_args != expected_args):
					print_error("warning: function '")
					print_error(callee_name)
					print_error("' expects ")
					print_error(itoa(expected_args))
					print_error(" arguments, got ")
					warning(itoa(passed_args))
			if (callee_name != 0):
				free(callee_name)

			mov_eax_esp_plus((stack_pos - s - 1) << word_size_log2)

			# A function's address is its value; other callees hold a pointer
			if (type != 4):
				promote(type)
			call_eax()
			be_pop(stack_pos - s)
			stack_pos = s
			type = 3  # call results are plain values

		else if (accept(".")):
			# Struct pointers are loaded first so fields work through them
			if (type_get_pointer_level(type) > 0):
				int element = type_lookup_previous_pointer(type)
				if (element >= 0):
					if (type_num_args(element) > 0):
						promote(type)
						type = element

			# For structures, find offset of field name
			int num_args = type_num_args(type)
			if (num_args > 0):
				int arg = type_get_arg(type, token)
				if(arg < 0):
					print2("struct field '")
					print2(token)
					error("' not found")

				# Return right side field type instead of struct pointer
				add_eax_int32(type_get_field_offset(type, token))

				# Use child type insted of struct type:
				type = type_get_field_type(type, token)
				if (type < 0):
					print_int0("child field not found: '", type)
					error("")
				if (verbosity >= 1):
					print2(itoa(line_number))
					print_string0(": using child type: ", type_get_name(type))
					print_int(": ", type)

			get_token()

		else:
			return type
