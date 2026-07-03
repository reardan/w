int type_name():
	int type = 0
	int is_const = 0
	pointer_indirection = 0
	if (accept("const")):
		is_const = 1
	type = type_lookup(token)
	if (type < 0):
		print_error("unknown type name: '")
		print_error(token)
		error("'")
	int checked_type = type_unqualified(type)
	if ((checked_type == float64_type) & (word_size != 8)):
		error("float64 requires the x64 target")
	if (((checked_type == int64_type) | (checked_type == uint64_type)) & (word_size != 8)):
		error("int64 requires the x64 target")

	get_token()

	if (is_const):
		type = type_push_const(type)

	# Each '*' wraps the base type in a pointer type, created on demand
	char* base_name = type_get_name(type)
	while (accept("*")):
		pointer_indirection = pointer_indirection + 1
		int pointer_type = type_lookup_pointer(base_name, pointer_indirection)
		if (pointer_type < 0):
			pointer_type = type_push_pointer(base_name, word_size, pointer_indirection)
		type = pointer_type

	return type
