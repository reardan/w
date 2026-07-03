int type_name():
	int type = 0
	pointer_indirection = 0
	type = type_lookup(token)
	if (type < 0):
		print_error("unknown type name: '")
		print_error(token)
		error("'")
	if ((type == float64_type) & (word_size != 8)):
		error("float64 requires the x64 target")

	get_token()

	# Each '*' wraps the base type in a pointer type, created on demand
	char* base_name = type_get_name(type)
	while (accept("*")):
		pointer_indirection = pointer_indirection + 1
		int pointer_type = type_lookup_pointer(base_name, pointer_indirection)
		if (pointer_type < 0):
			pointer_type = type_push_pointer(base_name, word_size, pointer_indirection)
		type = pointer_type

	return type
