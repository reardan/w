# Built-in list[T] elements are stored by value in byte-addressed slots.
# Reject element types the runtime cannot copy: void, and fixed arrays
# (their descriptors point into the enclosing object, so a byte copy
# would corrupt them). Scalars must fit in a word; structs may span
# several words but must not contain fixed-array fields.
void list_element_type_check(int element_type):
	int checked = type_unqualified(element_type)
	if (type_is_array(checked)):
		error(c"list element type cannot be a fixed-size array")
	if (type_get_size(checked) <= 0):
		error(c"list element type must have a size")
	if (type_has_array_field(checked)):
		error(c"list element type cannot contain fixed-size array fields")
	if (type_num_args(checked) == 0):
		if (type_stack_words(checked) != 1):
			error(c"list element type must be word-sized")


# Map values share the list element storage rules, except that scalar
# values may be any word-or-narrower type (stored in a word slot).
void map_value_type_check(int value_type):
	int checked = type_unqualified(value_type)
	if (type_is_array(checked)):
		error(c"map value type cannot be a fixed-size array")
	if (type_has_array_field(checked)):
		error(c"map value type cannot contain fixed-size array fields")
	if (type_num_args(checked) == 0):
		if (type_stack_words(checked) != 1):
			error(c"map value type must be word-sized")


int type_name():
	int type = 0
	int is_const = 0
	pointer_indirection = 0
	if (accept(c"const")):
		is_const = 1
	if (peek(c"map") & (nextc == '[')):
		get_token()
		expect(c"[")
		int key_type = type_name()
		expect(c",")
		int value_type = type_name()
		expect(c"]")
		map_value_type_check(value_type)
		type = type_get_map(key_type, value_type)
	else if (peek(c"set") & (nextc == '[')):
		get_token()
		expect(c"[")
		int set_key_type = type_name()
		expect(c"]")
		type = type_get_set(set_key_type)
	else if (peek(c"list") & (nextc == '[')):
		get_token()
		expect(c"[")
		int list_element = type_name()
		expect(c"]")
		list_element_type_check(list_element)
		type = type_get_list(list_element)
	else:
		type = type_lookup(token)
		if (type < 0):
			print_error(c"unknown type name: '")
			print_error(token)
			error(c"'")
		int checked_type = type_unqualified(type)
		if ((checked_type == float64_type) & (word_size != 8)):
			error(c"float64 requires the x64 target")
		if (((checked_type == int64_type) | (checked_type == uint64_type)) & (word_size != 8)):
			error(c"int64 requires the x64 target")

		get_token()

	if (is_const):
		type = type_push_const(type)

	# Each '*' wraps the base type in a pointer type, created on demand
	char* base_name = type_get_name(type)
	while (accept(c"*")):
		pointer_indirection = pointer_indirection + 1
		int pointer_type = type_lookup_pointer(base_name, pointer_indirection)
		if (pointer_type < 0):
			pointer_type = type_push_pointer(base_name, word_size, pointer_indirection)
		type = pointer_type

	while (accept(c"[")):
		if (accept(c"]")):
			int slice_type = type_lookup_slice(type)
			if (slice_type < 0):
				slice_type = type_push_slice(type)
			type = slice_type
		else:
			int array_length = atoi(token)
			if (array_length <= 0):
				error(c"array length must be positive")
			get_token()
			expect(c"]")
			int array_type = type_lookup_array(type, array_length)
			if (array_type < 0):
				array_type = type_push_array(type, array_length)
			type = array_type

	return type
