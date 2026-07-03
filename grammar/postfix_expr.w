# Warn when a call argument's type conflicts with the callee's declared
# parameter type. callee is the callee's symbol table offset (< 0 when the
# callee is unknown, e.g. calls through pointers); arg_index is 0-based.
void check_call_argument(int callee, char* callee_name, int arg_index, int arg_type):
	if (callee < 0):
		return;
	int param_type = sym_param_type(callee, arg_index)
	if (param_type < 0):
		return;
	if (types_compatible(param_type, arg_type) == 0):
		print_error("warning: function '")
		print_error(callee_name)
		print_error("' argument ")
		print_error(itoa(arg_index + 1))
		print_error(" type mismatch: expected '")
		print_error_type(param_type)
		print_error("', got '")
		print_error_type(arg_type)
		warning("'")


# Push a call argument onto the stack. Struct values are copied word by
# word, highest field offset first so field 0 lands at the lowest address
# (the layout parameter access expects); everything else is the one word
# in eax.
void push_call_argument(int arg_type):
	int arg_words = 1
	if (type_num_args(arg_type) > 0):
		arg_words = (type_get_size(arg_type) + word_size - 1) >> word_size_log2
	if (arg_words == 1):
		push_eax()
		stack_pos = stack_pos + 1
		return;
	# eax holds the struct's address (promote keeps structs as addresses)
	int j = arg_words - 1
	while (j >= 0):
		push_eax_plus(j << word_size_log2)
		j = j - 1
	stack_pos = stack_pos + arg_words


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
			int callee_sym = -1
			char* callee_name = 0
			if (type == 4):
				int callee = sym_lookup(last_identifier)
				if (callee >= 0):
					expected_args = sym_num_args(callee)
					if (expected_args >= 0):
						callee_sym = callee
						callee_name = strclone(last_identifier)

			int s = stack_pos
			push_eax()
			stack_pos = stack_pos + 1
			int passed_args = 0
			int arg_type
			if (accept(")") == 0):
				arg_type = expression()
				promote(arg_type)
				check_call_argument(callee_sym, callee_name, 0, arg_type)
				push_call_argument(arg_type)
				passed_args = 1
				while (accept(",")):
					arg_type = expression()
					promote(arg_type)
					check_call_argument(callee_sym, callee_name, passed_args, arg_type)
					push_call_argument(arg_type)
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
