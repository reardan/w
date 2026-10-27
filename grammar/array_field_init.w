void init_array_field_descriptors_at(int type, int offset);


void zero_runtime_object(int bytes):
	push_slot()
	push_slot_int(bytes)
	mov_eax_esp_plus(word_size)
	push_slot()
	zero_stack_count_bytes()
	drop_slots(2)
	pop_eax_slot()


void init_array_field_descriptor(int array_type, int offset):
	push_slot()
	mov_ebx_esp()
	if (offset > 0): add_ebx_int32(offset)
	mov_eax_ebx()
	add_eax_int32(2 * word_size)
	store_ebx_word()
	add_ebx_int32(word_size)
	mov_eax_int(type_get_array_length(array_type))
	store_ebx_word()
	pop_eax_slot()


# Build the descriptors inside every element of the array whose
# {data, length} descriptor sits at offset (issue #701): an element type
# that holds arrays itself (a struct with a fixed-array field, or an inner
# T[N]) carries its own headers, which nothing else writes. The walk reads
# the data pointer and length back from the descriptor, so one loop serves
# fixed arrays and runtime-length 'new T[n]' allocations alike, and the
# emitted code is one element's worth whatever the length. eax = the
# base address on entry and exit.
void init_array_element_descriptors(int element_type, int offset):
	if (type_has_array_field(element_type) == 0): return;
	push_slot()
	add_eax_int32(offset + word_size)
	promote_eax()
	push_slot()
	mov_eax_esp_plus(word_size)
	if (offset > 0): add_eax_int32(offset)
	promote_eax()
	push_slot()
	# stack: element cursor, elements left, base
	int h_done = be_ctrl_block()
	int h_top = be_ctrl_loop()
	mov_eax_esp_plus(word_size)
	be_br_zero(h_done)
	mov_eax_esp_plus(0)
	init_array_field_descriptors_at(element_type, 0)
	add_stack_word_int32(0, type_get_size(element_type))
	add_stack_word_int32(word_size, -1)
	be_br(h_top)
	be_ctrl_end(h_top)
	be_ctrl_end(h_done)
	drop_slots(2)
	pop_eax_slot()


void init_array_field_descriptors_at(int type, int offset):
	if (type_is_array(type)):
		init_array_field_descriptor(type, offset)
		init_array_element_descriptors(type_get_element_type(type), offset)
		return;
	int count = type_num_args(type)
	for i in range(count):
		int field_type = type_get_field_type_at(type, i)
		if (type_has_array_field(field_type)):
			init_array_field_descriptors_at(field_type, offset + type_get_field_offset_at(type, i))


void init_array_field_descriptors(int type):
	if (type_has_array_field(type)): init_array_field_descriptors_at(type, 0)
