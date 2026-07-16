int expression();
int promote(int type);
void coerce(int want, int got);
int types_compatible_with_expression(int want, int got);
void warn_type_mismatch(char* context, int want, int got);
int compound_assign_apply(int op, int left_type, int right_type);
int float_binary_arithmetic(int left_type, int right_type, int op);
int var_binary_operands(int left_type, int right_type);
int list_element_slot_size(int element_type);


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


# m[key] op= rhs: the map and key already sit in the pending stack slots,
# so the read and the write reuse them and the key is evaluated exactly
# once. The read traps on a missing key, same as m[key]. 'op' is the
# marker compound_assign_op() returned; the op token is still pending.
int hash_finish_pending_compound(int op):
	int saved_base_stack = hash_index_base_stack
	int saved_map_slot = hash_index_map_slot
	int saved_key_slot = hash_index_key_slot
	int value_type = type_map_value_type(hash_index_map_type)
	hash_index_pending = 0
	if (type_num_args(value_type) > 0):
		error(c"compound assignment is not supported on struct values")
	if (type_is_buffer(type_canonical(value_type))):
		error(c"compound assignment is not supported on string, array or slice values")

	# Load the current value; keep the parked slots for the store.
	sym_get_value(c"__w_map_get")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(saved_map_slot)
	hash_push_stack_slot(saved_key_slot)
	hash_call_finish(s)

	# Same shape the scalar path feeds compound_assign_apply: loaded left
	# value on top of the stack, promoted right value in eax.
	int left_type = type_value(value_type)
	push_eax()
	stack_pos = stack_pos + 1
	int right_type = promote(expression())
	if (var_binary_operands(left_type, right_type)):
		error(c"compound assignment does not support var operands")
	int result_type = compound_assign_apply(op, left_type, right_type)
	coerce(value_type, result_type)
	if (types_compatible_with_expression(value_type, result_type) == 0):
		warn_type_mismatch(c"map assignment", value_type, result_type)

	# Store back through the same map/key slots.
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	sym_get_value(c"__w_map_set")
	s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(saved_map_slot)
	hash_push_stack_slot(saved_key_slot)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)

	# Like '=', the expression yields the stored value.
	mov_eax_esp_plus((stack_pos - value_slot) << word_size_log2)
	be_pop(stack_pos - saved_base_stack)
	stack_pos = saved_base_stack
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


# m.add(key) / m.add(key, delta): 'add' has been consumed, delta defaults
# to 1. Integer values lower to __w_map_add(map, key, delta): one probe,
# and zeroed value slots make a missing key accumulate from zero. Float
# values (float32 everywhere, float64 on x64 — issue #189) reuse the
# float emitters instead of a runtime variant: load the current value
# with __w_map_get_or(map, key, 0) — zero bits are 0.0, so missing keys
# accumulate from zero the same way — add the delta exactly like the
# m[key] += path and store back through __w_map_set. The parked map/key
# slots feed both calls, so the key is evaluated once. Either way the
# expression yields the updated value. float16 values stay rejected: the
# slot word holds raw half bits the float emitters cannot add directly.
# (A runtime float variant in structures/hash_table.w could not cover
# float64, whose type is rejected on 32-bit targets, so the dispatch
# lives here.)
int hash_map_add_suffix(int type):
	int container_type = type_unqualified(type)
	int value_type = type_map_value_type(container_type)
	int key_type = type_map_key_type(container_type)
	if (type_num_args(value_type) > 0):
		error(c"map add requires an integer or float value type")
	if (type_canonical(value_type) == float16_type):
		error(c"map add does not support float16 values")
	int value_kind = type_float_kind(type_value(value_type))
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
		warn_type_mismatch(c"map add key", key_type, got_type)
	push_eax()
	stack_pos = stack_pos + 1
	int key_slot = stack_pos
	if (accept(c",")):
		int delta_got = expression()
		delta_got = promote(delta_got)
		coerce(value_type, delta_got)
		if (types_compatible_with_expression(value_type, delta_got) == 0):
			warn_type_mismatch(c"map add delta", value_type, delta_got)
	else:
		mov_eax_int(1)
		if (value_kind):
			coerce(value_type, 3)
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int delta_slot = stack_pos
	int s = 0
	if (value_kind):
		# current = __w_map_get_or(map, key, 0): 0.0 when key is missing
		sym_get_value(c"__w_map_get_or")
		s = stack_pos
		push_eax()
		stack_pos = stack_pos + 1
		hash_push_stack_slot(container_slot)
		hash_push_stack_slot(key_slot)
		mov_eax_int(0)
		push_eax()
		stack_pos = stack_pos + 1
		hash_call_finish(s)
		# current + delta, same operand shape as compound_assign_apply:
		# left (current) into ebx, right (delta) reloaded into eax
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_esp_plus((stack_pos - delta_slot) << word_size_log2)
		pop_ebx()
		stack_pos = stack_pos - 1
		float_binary_arithmetic(type_value(value_type), type_value(value_type), '+')
		# store the sum back through the parked slots and yield it
		push_eax()
		stack_pos = stack_pos + 1
		int sum_slot = stack_pos
		sym_get_value(c"__w_map_set")
		s = stack_pos
		push_eax()
		stack_pos = stack_pos + 1
		hash_push_stack_slot(container_slot)
		hash_push_stack_slot(key_slot)
		hash_push_stack_slot(sum_slot)
		hash_call_finish(s)
		mov_eax_esp_plus((stack_pos - sum_slot) << word_size_log2)
	else:
		sym_get_value(c"__w_map_add")
		s = stack_pos
		push_eax()
		stack_pos = stack_pos + 1
		hash_push_stack_slot(container_slot)
		hash_push_stack_slot(key_slot)
		hash_push_stack_slot(delta_slot)
		hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(value_type)


# Shared lowering for m.keys()/s.keys()/m.values(): parses '()', calls
# fn_name(container, element_size) and returns list[element_type] with
# the snapshot's address in eax.
int hash_snapshot_list_suffix(int type, char* fn_name, int element_type):
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int container_slot = stack_pos
	expect(c"(")
	expect(c")")
	sym_get_value(fn_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(container_slot)
	mov_eax_int(list_element_slot_size(type_canonical(element_type)))
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_get_list(type_canonical(element_type)))


# m.keys() / s.keys(): 'keys' has been consumed. Snapshot of the keys
# (set members) in insertion order as a built-in list[K].
int hash_keys_suffix(int type):
	int container_type = type_unqualified(type)
	return hash_snapshot_list_suffix(type, c"__w_map_keys", hash_container_key_type(container_type))


# m.values(): 'values' has been consumed. Snapshot of the values in
# insertion order as a built-in list[V].
int hash_values_suffix(int type):
	int container_type = type_unqualified(type)
	return hash_snapshot_list_suffix(type, c"__w_map_values", type_map_value_type(container_type))


# m.get(key) / m.get(key, default): 'get' has been consumed.
#   m.get(key)          traps on a missing key, same as m[key]
#   m.get(key, default) evaluates default and returns it instead of trapping
int hash_get_suffix(int type):
	int container_type = type_unqualified(type)
	int value_type = type_map_value_type(container_type)
	int key_type = type_map_key_type(container_type)
	int value_is_struct = type_num_args(value_type) > 0
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
		warn_type_mismatch(c"map get key", key_type, got_type)
	push_eax()
	stack_pos = stack_pos + 1
	int key_slot = stack_pos
	int has_default = 0
	int default_slot = 0
	if (accept(c",")):
		has_default = 1
		int default_got = expression()
		default_got = promote(default_got)
		coerce(value_type, default_got)
		if (types_compatible_with_expression(value_type, default_got) == 0):
			warn_type_mismatch(c"map get default", value_type, default_got)
		push_eax()
		stack_pos = stack_pos + 1
		default_slot = stack_pos
	expect(c")")

	char* fn_name = c"__w_map_get"
	if (has_default):
		fn_name = c"__w_map_get_or"
		if (value_is_struct):
			fn_name = c"__w_map_get_or_addr"
	else if (value_is_struct):
		fn_name = c"__w_map_get_addr"
	sym_get_value(fn_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(container_slot)
	hash_push_stack_slot(key_slot)
	if (has_default):
		hash_push_stack_slot(default_slot)
	hash_call_finish(s)

	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	if (value_is_struct):
		return type_canonical(value_type)
	return type_value(value_type)
