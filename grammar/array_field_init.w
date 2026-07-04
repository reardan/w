void zero_runtime_object(int bytes):
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_int(bytes)
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_esp_plus(word_size)
	push_eax()
	stack_pos = stack_pos + 1
	zero_stack_count_bytes()
	be_pop(2)
	stack_pos = stack_pos - 2
	pop_eax()
	stack_pos = stack_pos - 1


void init_array_field_descriptor(int array_type, int offset):
	push_eax()
	stack_pos = stack_pos + 1
	mov_ebx_esp()
	if (offset > 0):
		add_ebx_int32(offset)
	mov_eax_ebx()
	add_eax_int32(2 * word_size)
	store_ebx_word()
	add_ebx_int32(word_size)
	mov_eax_int(type_get_array_length(array_type))
	store_ebx_word()
	pop_eax()
	stack_pos = stack_pos - 1


void init_array_field_descriptors_at(int type, int offset):
	if (type_is_array(type)):
		init_array_field_descriptor(type, offset)
		return;
	int count = type_num_args(type)
	int i = 0
	while (i < count):
		int field_type = type_get_field_type_at(type, i)
		if (type_has_array_field(field_type)):
			init_array_field_descriptors_at(field_type, offset + type_get_field_offset_at(type, i))
		i = i + 1


void init_array_field_descriptors(int type):
	if (type_has_array_field(type)):
		init_array_field_descriptors_at(type, 0)
