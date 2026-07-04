int variable_declaration():
	# type-name identifier
	if (peek("const") | (peek("map") & (nextc == '[')) | (peek("set") & (nextc == '[')) | (type_lookup(token) >= 0)):
		# println2("variable_declaration()")
		int type = typed_identifier()
		int has_initializer = 0
		int type2 = -1
		# = expression
		if (accept("=")):
			has_initializer = 1
			if (type_is_array(type)):
				error("fixed array initializer is not implemented")
			type2 = expression()
			type2 = promote(type2)
			coerce(type, type2)
			if (types_compatible_with_expression(type, type2) == 0):
				warn_type_mismatch("initialization", type, type2)
			if (verbosity >= 0):
				print2("variable declaration = expression() right side type: ")
				type_print(type2)
		save_int(table + last_declared_symbol + 2, stack_pos)
		pointer_indirection = 0

		# Reserve enough words for aggregate storage, else 1 word.
		int size = type_stack_words(type)
		int num_args = type_num_args(type)
		if ((num_args > 0) & (type_is_array(type) == 0)):
			if (has_initializer):
				int j = size - 1
				while (j >= 0):
					push_eax_plus(j << word_size_log2)
					j = j - 1
				stack_pos = stack_pos + size
				return type
		if (type_is_array(type)):
			mov_eax_int(0)
		int i = 0
		while (i < size):
			push_eax()
			i = i + 1
		stack_pos = stack_pos + size
		if (type_is_array(type)):
			lea_eax_esp_plus(2 * word_size)
			store_stack_var(0)
			mov_eax_int(type_get_array_length(type))
			store_stack_var(word_size)
		return type
	return -1


