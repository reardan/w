# Declared return type of the most recently compiled call (-1 when the
# callee is unknown) and the code position right after its cleanup. Only
# the REPL reads these, to avoid echoing a void call's garbage result.
int last_call_return_type
int last_call_end
int expression_lhs_readonly


int buffer_element_type(int type):
	if (type_is_string(type)):
		return type_lookup(c"char")
	if (type_is_array(type) | type_is_slice(type)):
		return type_get_element_type(type)
	return type_lookup(c"char")


int buffer_result_type(int type):
	if (type_is_string(type)):
		return string_value_type
	return type_get_slice_value(buffer_element_type(type))


void buffer_bounds_check():
	if (bounds_mode == 0):
		return;
	bounds_check_eax_nonnegative()
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(word_size)
	add_eax_int32(word_size)
	promote_eax()
	pop_ebx()
	stack_pos = stack_pos - 1
	bounds_check_ebx_less_eax()
	mov_eax_ebx()


void buffer_range_bounds_check():
	if (bounds_mode == 0):
		return;
	# stack top before this helper: end, start, descriptor
	mov_eax_esp_plus(word_size)
	bounds_check_eax_nonnegative()
	mov_eax_esp_plus(0)
	bounds_check_eax_nonnegative()
	mov_eax_esp_plus(0)
	mov_ebx_esp_plus(word_size)
	bounds_check_ebx_less_equal_eax()
	mov_eax_esp_plus(2 * word_size)
	add_eax_int32(word_size)
	promote_eax()
	mov_ebx_esp_plus(0)
	bounds_check_ebx_less_equal_eax()


void buffer_push_range_descriptor(int base_type, int start_was_omitted):
	int element_type = buffer_element_type(base_type)
	int element_size = type_get_size(element_type)
	# stack top before this helper: end, start, descriptor
	sym_get_value(c"malloc")
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_int(2 * word_size)
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(word_size)
	call_eax()
	be_pop(2)
	stack_pos = stack_pos - 2

	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(2 * word_size)
	mov_ebx_esp_plus(word_size)
	alu_sub()
	mov_ebx_esp()
	add_ebx_int32(word_size)
	store_ebx_word()

	mov_eax_esp_plus(2 * word_size)
	if (element_size > 1):
		imul_eax_int32(element_size)
	mov_ebx_esp_plus(3 * word_size)
	promote_ebx()
	alu_add()
	mov_ebx_esp()
	store_ebx_word()

	pop_eax()
	stack_pos = stack_pos - 1
	be_pop(3)
	stack_pos = stack_pos - 3


# Warn when a call argument's type conflicts with the callee's declared
# parameter type. callee is the callee's symbol table offset (< 0 when the
# callee is unknown, e.g. calls through pointers); arg_index is 0-based.
void check_call_argument(int callee, int signature_type, char* callee_name, int arg_index, int arg_type):
	int param_type = -1
	if (signature_type >= 0):
		param_type = type_function_param_type(signature_type, arg_index)
	else if (callee >= 0):
		param_type = sym_param_type(callee, arg_index)
	if (param_type < 0):
		return;
	if (types_compatible_with_expression(param_type, arg_type) == 0):
		diag_part(c"warning: function '")
		diag_part(callee_name)
		diag_part(c"' argument ")
		diag_part(itoa(arg_index + 1))
		diag_part(c" type mismatch: expected '")
		print_error_type(param_type)
		diag_part(c"', got '")
		print_error_type(arg_type)
		warning(c"'")


void init_array_field_descriptors(int type);
void coerce_cstr_to_string_call_arg();


void coerce_call_argument(int param_type, int arg_type):
	if (type_is_string(param_type) & type_is_char_pointer(arg_type)):
		coerce_cstr_to_string_call_arg()
	else:
		coerce(param_type, arg_type)


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
	if (type_has_array_field(arg_type)):
		lea_eax_esp_plus(0)
		init_array_field_descriptors(arg_type)


# Parse arguments for a call whose callee address has already been pushed.
# passed_args lets callers account for hidden arguments, such as a method
# receiver. callee_type is 4 for direct functions, and a pointer type for
# indirect calls through function-pointer values.
int parse_call_suffix(int callee_type, int s, int expected_args, int callee_sym, int signature_type, char* callee_name, int declared_return, int passed_args, int has_return_buffer):
	int arg_type
	if (accept(c")") == 0):
		arg_type = expression()
		arg_type = promote(arg_type)
		check_call_argument(callee_sym, signature_type, callee_name, passed_args, arg_type)
		if ((callee_sym >= 0) | (signature_type >= 0)):
			int param_type = -1
			if (callee_sym >= 0):
				param_type = sym_param_type(callee_sym, passed_args)
			if (signature_type >= 0):
				param_type = type_function_param_type(signature_type, passed_args)
			if (param_type >= 0):
				coerce_call_argument(param_type, arg_type)
		push_call_argument(arg_type)
		passed_args = passed_args + 1
		while (accept(c",")):
			arg_type = expression()
			arg_type = promote(arg_type)
			check_call_argument(callee_sym, signature_type, callee_name, passed_args, arg_type)
			if ((callee_sym >= 0) | (signature_type >= 0)):
				int param_type = -1
				if (callee_sym >= 0):
					param_type = sym_param_type(callee_sym, passed_args)
				if (signature_type >= 0):
					param_type = type_function_param_type(signature_type, passed_args)
				if (param_type >= 0):
					coerce_call_argument(param_type, arg_type)
			push_call_argument(arg_type)
			passed_args = passed_args + 1

		expect(c")")

	if (expected_args >= 0):
		if (passed_args != expected_args):
			diag_part(c"warning: function '")
			diag_part(callee_name)
			diag_part(c"' expects ")
			diag_part(itoa(expected_args))
			diag_part(c" arguments, got ")
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
	if (has_return_buffer):
		lea_eax_esp_plus(0)
		type = type_value(declared_return)
	else if (declared_return >= 0):
		type = type_value(declared_return)
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
		if (accept(c"[")):
			expression_lhs_readonly = 0
			if (type_is_map(type)):
				int map_type = type_unqualified(type)
				hash_index_base_stack = stack_pos
				type = promote(type)
				push_eax()
				stack_pos = stack_pos + 1
				hash_index_map_slot = stack_pos
				int want_key_type = type_map_key_type(map_type)
				int got_key_type = expression()
				got_key_type = promote(got_key_type)
				coerce(want_key_type, got_key_type)
				if (types_compatible_with_expression(want_key_type, got_key_type) == 0):
					warn_type_mismatch(c"map key", want_key_type, got_key_type)
				push_eax()
				stack_pos = stack_pos + 1
				hash_index_key_slot = stack_pos
				expect(c"]")
				hash_index_map_type = map_type
				hash_index_pending = 1
				type = type_map_value_type(map_type)
			else if (type_is_buffer(type)):
				type = promote(type)
				if (accept(c":")):
					push_eax()
					stack_pos = stack_pos + 1
					mov_eax_int(0)
					push_eax()
					stack_pos = stack_pos + 1
					if (accept(c"]")):
						mov_eax_esp_plus(word_size)
						add_eax_int32(word_size)
						promote_eax()
					else:
						promote(expression())
						expect(c"]")
					push_eax()
					stack_pos = stack_pos + 1
					buffer_range_bounds_check()
					buffer_push_range_descriptor(type, 1)
					type = buffer_result_type(type)
					expression_lhs_readonly = 1
				else:
					push_eax()
					stack_pos = stack_pos + 1
					int element_type = buffer_element_type(type)
					int element_size = type_get_size(element_type)
					promote(expression())
					if (accept(c":")):
						push_eax()
						stack_pos = stack_pos + 1
						if (accept(c"]")):
							mov_eax_esp_plus(word_size)
							add_eax_int32(word_size)
							promote_eax()
						else:
							promote(expression())
							expect(c"]")
						push_eax()
						stack_pos = stack_pos + 1
						buffer_range_bounds_check()
						buffer_push_range_descriptor(type, 0)
						type = buffer_result_type(type)
						expression_lhs_readonly = 1
					else:
						buffer_bounds_check()
						if (element_size > 1):
							imul_eax_int32(element_size)
						pop_ebx()
						promote_ebx()
						alu_add()
						stack_pos = stack_pos - 1
						expect(c"]")
						type = element_type
						expression_lhs_readonly = 0
			else:
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
				expect(c"]")
				type = element_type
				expression_lhs_readonly = 0

		else if (accept(c"(")):
			# Remember the callee's declared arity now; parsing the arguments
			# below overwrites last_identifier.
			int expected_args = -1
			int callee_sym = -1
			int signature_type = -1
			char* callee_name = 0
			int declared_return = -1
			if (type == 4):
				int callee = sym_lookup(last_identifier)
				if (callee >= 0):
					declared_return = load_int(table + callee + 6)
					# asm runtime stubs are declared with the 'function'
					# pseudo-type: their call results are untyped words
					if (declared_return == 4):
						declared_return = -1
					expected_args = sym_num_args(callee)
					if (expected_args >= 0):
						callee_sym = callee
						callee_name = strclone(last_identifier)
			else if (type_get_pointer_level(type) > 0):
				int base_type = type_lookup_previous_pointer(type)
				if ((base_type >= 0) & (type_is_function_signature(base_type))):
					signature_type = base_type
					declared_return = type_function_return(base_type)
					expected_args = type_function_param_count(base_type)
					callee_name = strclone(c"function pointer")

			int has_return_buffer = 0
			int s = stack_pos
			if (declared_return >= 0):
				if (type_num_args(declared_return) > 0):
					int words = (type_get_size(declared_return) + word_size - 1) >> word_size_log2
					int j = 0
					while (j < words):
						push_eax()
						j = j + 1
					stack_pos = stack_pos + words
					s = stack_pos
					has_return_buffer = 1
			push_eax()
			stack_pos = stack_pos + 1
			if (has_return_buffer):
				lea_eax_esp_plus(word_size)
				push_eax()
				stack_pos = stack_pos + 1
			type = parse_call_suffix(type, s, expected_args, callee_sym, signature_type, callee_name, declared_return, 0, has_return_buffer)

		else if (accept(c".")):
			expression_lhs_readonly = 0
			if (type_is_map(type) | type_is_set(type)):
				if (peek(c"length")):
					get_token()
					type = promote(type)
					add_eax_int32(word_size)
					type = type_lookup(c"int")
					expression_lhs_readonly = 1
				else:
					print2(c"hash container field '")
					print2(token)
					error(c"' not found")
			else if (type_is_buffer(type)):
				if (peek(c"length")):
					get_token()
					type = promote(type)
					add_eax_int32(word_size)
					type = type_lookup(c"int")
					expression_lhs_readonly = 1
				else if (peek(c"data")):
					get_token()
					type = promote(type)
					int element_type = buffer_element_type(type)
					type = type_get_next_pointer(element_type)
					expression_lhs_readonly = 1
				else:
					print2(c"buffer field '")
					print2(token)
					error(c"' not found")
			else:
				int receiver_struct_value_words = 0
				int receiver_was_value = type_is_value(type)
				if (receiver_was_value):
					int receiver_real_type = type_real(type)
					if (type_num_args(receiver_real_type) > 0):
						receiver_struct_value_words = (type_get_size(receiver_real_type) + word_size - 1) >> word_size_log2
					type = promote(type)

				# Struct pointers are loaded first so fields work through them
				if (type_get_pointer_level(type) > 0):
					int element = type_lookup_previous_pointer(type)
					if (element >= 0):
						if (type_num_args(element) > 0):
							if (receiver_was_value == 0):
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
							print_int0(c"child field not found: '", type)
							error(c"")
						if (verbosity >= 1):
							print2(itoa(line_number))
							print_string0(c": using child type: ", type_get_name(type))
							print_int(c": ", type)
						if (receiver_struct_value_words > 0):
							if (type_num_args(type) == 0):
								type = promote(type)
								be_pop(receiver_struct_value_words)
								stack_pos = stack_pos - receiver_struct_value_words
								type = type_value(type)
					else if (peek(c"(")):
						char* prefix = strjoin(type_get_name(type), c"_")
						char* method_symbol = strjoin(prefix, member_name)
						free(prefix)
						int callee = sym_lookup(method_symbol)
						if (callee < 0):
							print_error(c"struct method '")
							print_error(type_get_name(type))
							print_error(c".")
							print_error(member_name)
							print_error(c"' not found; expected function '")
							print_error(method_symbol)
							error(c"'")

						int expected_args = sym_num_args(callee)
						int callee_sym = -1
						int signature_type = -1
						char* callee_name = 0
						if (expected_args >= 0):
							callee_sym = callee
							callee_name = strclone(method_symbol)
						int declared_return = load_int(table + callee + 6)

						int has_return_buffer = 0
						int return_words = 0
						if (declared_return >= 0):
							if (type_num_args(declared_return) > 0):
								return_words = (type_get_size(declared_return) + word_size - 1) >> word_size_log2
								int j = 0
								while (j < return_words):
									push_eax()
									j = j + 1
								stack_pos = stack_pos + return_words
								has_return_buffer = 1

						# Save the receiver address while resolving the method
						# symbol, then push it as the hidden first source argument.
						push_eax()
						stack_pos = stack_pos + 1
						sym_get_value(method_symbol)
						int s = stack_pos
						push_eax()
						stack_pos = stack_pos + 1
						if (has_return_buffer):
							lea_eax_esp_plus(2 << word_size_log2)
							push_eax()
							stack_pos = stack_pos + 1
						if (has_return_buffer):
							mov_eax_esp_plus(2 << word_size_log2)
						else:
							mov_eax_esp_plus(1 << word_size_log2)

						int receiver_type = type_lookup_next_pointer(type)
						check_call_argument(callee_sym, signature_type, callee_name, 0, receiver_type)
						if (callee_sym >= 0):
							int param_type = sym_param_type(callee_sym, 0)
							if (param_type >= 0):
								coerce(param_type, receiver_type)
						push_call_argument(receiver_type)

						accept(c"(")
						type = parse_call_suffix(4, s, expected_args, callee_sym, signature_type, callee_name, declared_return, 1, has_return_buffer)
						be_pop(1)
						stack_pos = stack_pos - 1
						if (has_return_buffer):
							lea_eax_esp_plus(0)
							type = type_value(declared_return)
						free(method_symbol)
					else:
						print2(c"struct field '")
						print2(member_name)
						error(c"' not found")
					free(member_name)

				else:
					get_token()

		else:
			return type
