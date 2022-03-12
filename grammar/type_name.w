/*
typename:
	0 = void
	1 = int
	2 = char
*/
int type_name():
	int type = 0
	pointer_indirection = 0
	type = type_lookup(token)
	if (type < 0):
		print_error("unknown type name: '")
		print_error(token)
		error("'")

	char* token_copy = strclone(token)
	get_token()

	int all_pointer_level = 0
	while (accept("*")) {
		all_pointer_level = all_pointer_level + 1
		if (type != 2):
			if (verbosity >= 1):
				warning("'*' accepted")
			pointer_indirection = pointer_indirection + 1
	}
	if (all_pointer_level > 0):
		int next_pointer_type = type_lookup_pointer(token_copy, all_pointer_level)
		if (verbosity >= 1):
			print2(itoa(line_number))
			print2(": FOUND POINTER INDIRECTION DECLARATION: ")
			print_int(": pointer_type: ", next_pointer_type)
		# TODO: fix type system so this works:
		# return next_pointer_type

	free(token_copy)
	return type
