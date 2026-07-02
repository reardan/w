int variable_declaration():
	# type-name identifier
	if (type_lookup(token) >= 0):
		# println2("variable_declaration()")
		int type = typed_identifier()
		# = expression
		if (accept("=")):
			int type2 = expression()
			# TODO: Fix to use & instead?  e.g. int*f = &func
			if (pointer_indirection == 0)
				promote(type2)
			if (verbosity >= 0):
				print2("variable declaration = expression() right side type: ")
				type_print(type2)
		pointer_indirection = 0

		# Reserve enough words for the struct's byte size, else 1 word
		int size = 1
		int num_args = type_num_args(type)
		if (num_args > 0):
			size = (type_get_size(type) + word_size - 1) >> word_size_log2
		int i = 0
		while (i < size):
			push_eax()
			i = i + 1
		stack_pos = stack_pos + size
		return type
	return -1


