int variable_declaration():
	# type-name identifier
	if (type_lookup(token) >= 0):
		# println2("statement(): type identifier")
		int type = typed_identifier()
		# = expression
		if (accept("=")):
			int type = expression()
			# TODO: Fix to use & instead?  e.g. int*f = &func
			if (pointer_indirection == 0)
				promote(type)
		pointer_indirection = 0

		# Compute size of struct else use 1 word
		int size = 1
		int num_args = type_num_args(type)
		if (num_args > 0):
			# print_string("num_args > 0 for ", token)
			size = num_args
		int i = 0
		while (i < size):
			be_push()
			i = i + 1
		stack_pos = stack_pos + size
		return type
	return 0-1


