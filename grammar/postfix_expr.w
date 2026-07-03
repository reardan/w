# Declared return type of the most recently compiled call (-1 when the
# callee is unknown) and the code position right after its cleanup. Only
# the REPL reads these, to avoid echoing a void call's garbage result.
int last_call_return_type
int last_call_end


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


# Parse arguments for a call whose callee address has already been pushed.
# passed_args lets callers account for hidden arguments, such as a method
# receiver. callee_type is 4 for direct functions, and a pointer type for
# indirect calls through function-pointer values.
int parse_call_suffix(int callee_type, int s, int expected_args, int callee_sym, char* callee_name, int declared_return, int passed_args):
	int arg_type
	if (accept(")") == 0):
		arg_type = expression()
		arg_type = promote(arg_type)
		check_call_argument(callee_sym, callee_name, passed_args, arg_type)
		if (callee_sym >= 0):
			int param_type = sym_param_type(callee_sym, passed_args)
			if (param_type >= 0):
				coerce(param_type, arg_type)
		push_call_argument(arg_type)
		passed_args = passed_args + 1
		while (accept(",")):
			arg_type = expression()
			arg_type = promote(arg_type)
			check_call_argument(callee_sym, callee_name, passed_args, arg_type)
			if (callee_sym >= 0):
				int param_type = sym_param_type(callee_sym, passed_args)
				if (param_type >= 0):
					coerce(param_type, arg_type)
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
	if (callee_type != 4):
		promote(callee_type)
	call_eax()
	be_pop(stack_pos - s)
	stack_pos = s
	int type = 3  # call results are plain values
	last_call_return_type = declared_return
	last_call_end = codepos
	if (type_float_kind(declared_return) == 2):
		type = float64_value_type
	else if (type_float_kind(declared_return) == 1):
		type = float32_value_type
	return type


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
			alu_add()
			stack_pos = stack_pos - 1
			expect("]")
			type = element_type

		else if (accept("(")):
			# Remember the callee's declared arity now; parsing the arguments
			# below overwrites last_identifier.
			int expected_args = -1
			int callee_sym = -1
			char* callee_name = 0
			int declared_return = -1
			if (type == 4):
				int callee = sym_lookup(last_identifier)
				if (callee >= 0):
					declared_return = load_int(table + callee + 6)
					expected_args = sym_num_args(callee)
					if (expected_args >= 0):
						callee_sym = callee
						callee_name = strclone(last_identifier)

			int s = stack_pos
			push_eax()
			stack_pos = stack_pos + 1
			type = parse_call_suffix(type, s, expected_args, callee_sym, callee_name, declared_return, 0)

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
				char* member_name = strclone(token)
				int arg = type_get_arg(type, member_name)
				get_token()

				if (arg >= 0):
					# Return right side field type instead of struct pointer
					add_eax_int32(type_get_field_offset(type, member_name))

					# Use child type insted of struct type:
					type = type_get_field_type(type, member_name)
					if (type < 0):
						print_int0("child field not found: '", type)
						error("")
					if (verbosity >= 1):
						print2(itoa(line_number))
						print_string0(": using child type: ", type_get_name(type))
						print_int(": ", type)
				else if (peek("(")):
					char* prefix = strjoin(type_get_name(type), "_")
					char* method_symbol = strjoin(prefix, member_name)
					free(prefix)
					int callee = sym_lookup(method_symbol)
					if (callee < 0):
						print_error("struct method '")
						print_error(type_get_name(type))
						print_error(".")
						print_error(member_name)
						print_error("' not found; expected function '")
						print_error(method_symbol)
						error("'")

					int expected_args = sym_num_args(callee)
					int callee_sym = -1
					char* callee_name = 0
					if (expected_args >= 0):
						callee_sym = callee
						callee_name = strclone(method_symbol)
					int declared_return = load_int(table + callee + 6)

					# Save the receiver address while resolving the method
					# symbol, then push it as the hidden first argument.
					push_eax()
					stack_pos = stack_pos + 1
					int s = stack_pos
					sym_get_value(method_symbol)
					push_eax()
					stack_pos = stack_pos + 1
					mov_eax_esp_plus(1 << word_size_log2)

					int receiver_type = type_lookup_next_pointer(type)
					check_call_argument(callee_sym, callee_name, 0, receiver_type)
					if (callee_sym >= 0):
						int param_type = sym_param_type(callee_sym, 0)
						if (param_type >= 0):
							coerce(param_type, receiver_type)
					push_call_argument(receiver_type)

					accept("(")
					type = parse_call_suffix(4, s, expected_args, callee_sym, callee_name, declared_return, 1)
					be_pop(1)
					stack_pos = stack_pos - 1
					free(method_symbol)
				else:
					print2("struct field '")
					print2(member_name)
					error("' not found")
				free(member_name)

			else:
				get_token()

		else:
			return type
