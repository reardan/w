int expression();
int promote(int type);
void coerce(int want, int got);
int types_compatible_with_expression(int want, int got);
void warn_type_mismatch(char* context, int want, int got);


int hash_index_pending
int hash_index_base_stack
int hash_index_map_slot
int hash_index_key_slot
int hash_index_map_type


int hash_key_kind_for_type(int type):
	type = type_unqualified(type)
	if (type_is_string(type)):
		return 3
	if (type_get_pointer_level(type) == 1):
		int base = type_lookup_previous_pointer(type)
		if (base >= 0):
			if (strcmp(type_get_name(base), c"char") == 0):
				return 2
	return 1


void hash_call_finish(int s):
	mov_eax_esp_plus((stack_pos - s - 1) << word_size_log2)
	call_eax()
	be_pop(stack_pos - s)
	stack_pos = s


void hash_push_stack_slot(int slot):
	mov_eax_esp_plus((stack_pos - slot) << word_size_log2)
	push_eax()
	stack_pos = stack_pos + 1


void hash_emit_new_container(int type):
	int key_type = type_set_key_type(type)
	char* fn_name = c"__w_set_new"
	if (type_is_map(type)):
		key_type = type_map_key_type(type)
		fn_name = c"__w_map_new"
	sym_get_value(fn_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_int(hash_key_kind_for_type(key_type))
	push_eax()
	stack_pos = stack_pos + 1
	if (type_is_map(type)):
		mov_eax_int(type_get_size(type_map_value_type(type)))
		push_eax()
		stack_pos = stack_pos + 1
	hash_call_finish(s)


int hash_finish_pending_read():
	int value_type = type_map_value_type(hash_index_map_type)
	# Struct values are stored by value in the table; the read yields the
	# stored bytes' address, which is exactly how W passes structs around,
	# so the result keeps the struct's own (address-based) type. Reads
	# copy immediately; the address is only valid until the next insert.
	int value_is_struct = type_num_args(value_type) > 0
	if (value_is_struct):
		sym_get_value(c"__w_map_get_addr")
	else:
		sym_get_value(c"__w_map_get")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(hash_index_map_slot)
	hash_push_stack_slot(hash_index_key_slot)
	hash_call_finish(s)
	be_pop(stack_pos - hash_index_base_stack)
	stack_pos = hash_index_base_stack
	hash_index_pending = 0
	if (value_is_struct):
		return type_canonical(value_type)
	return type_value(value_type)


int hash_finish_pending_assignment():
	int saved_base_stack = hash_index_base_stack
	int saved_map_slot = hash_index_map_slot
	int saved_key_slot = hash_index_key_slot
	int saved_map_type = hash_index_map_type
	hash_index_pending = 0
	int value_type = type_map_value_type(hash_index_map_type)
	int got_type = expression()
	got_type = promote(got_type)
	coerce(value_type, got_type)
	if (types_compatible_with_expression(value_type, got_type) == 0):
		warn_type_mismatch(c"map assignment", value_type, got_type)
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	hash_index_base_stack = saved_base_stack
	hash_index_map_slot = saved_map_slot
	hash_index_key_slot = saved_key_slot
	hash_index_map_type = saved_map_type

	# Struct sources arrive as addresses; copy their bytes into the table
	if ((type_num_args(value_type) > 0) & (type_num_args(type_real(got_type)) > 0)):
		sym_get_value(c"__w_map_set_bytes")
	else:
		sym_get_value(c"__w_map_set")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(hash_index_map_slot)
	hash_push_stack_slot(hash_index_key_slot)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)

	mov_eax_esp_plus((stack_pos - value_slot) << word_size_log2)
	be_pop(stack_pos - hash_index_base_stack)
	stack_pos = hash_index_base_stack
	return type_value(value_type)


int hash_finalize_pending_read_if_needed(int type):
	if (hash_index_pending):
		return hash_finish_pending_read()
	return type


int hash_container_key_type(int container_type):
	if (type_is_map(container_type)):
		return type_map_key_type(container_type)
	return type_set_key_type(container_type)


# Shared lowering for the map/set pseudo-methods that take one key
# argument: parses '(key)', checks it against the container's key type
# and calls fn_name(container, key). The call result stays in eax.
void hash_key_call_suffix(int type, char* fn_name, char* context):
	int container_type = type_unqualified(type)
	int key_type = hash_container_key_type(container_type)
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int container_slot = stack_pos
	expect(c"(")
	int got_type = expression()
	got_type = promote(got_type)
	coerce(key_type, got_type)
	if (types_compatible_with_expression(key_type, got_type) == 0):
		warn_type_mismatch(context, key_type, got_type)
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int key_slot = stack_pos
	sym_get_value(fn_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(container_slot)
	hash_push_stack_slot(key_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack


# m.remove(key) / s.remove(key): 'remove' has been consumed. Lowers to
# __w_map_remove(container, key), which returns 1 when the key existed.
int hash_remove_suffix(int type):
	hash_key_call_suffix(type, c"__w_map_remove", c"container remove key")
	return type_value(bool_type)


# s.add(key): 'add' has been consumed. Lowers to __w_set_add(set, key).
int hash_set_add_suffix(int type):
	hash_key_call_suffix(type, c"__w_set_add", c"set add key")
	return type_value(type_lookup(c"void"))
