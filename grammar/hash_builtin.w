int expression();
int promote(int type);
void coerce(int want, int got);
void coerce_checked(int want, int got, char* context);
int parse_coerced(int want, char* context);
void error_type(char* prefix, int type_index, char* suffix);
int types_compatible_with_expression(int want, int got);
void warn_type_mismatch(char* context, int want, int got);
int compound_assign_apply(int op, int left_type, int right_type);
int float_binary_arithmetic(int left_type, int right_type, int op);
int var_binary_operands(int left_type, int right_type);
int list_element_slot_size(int element_type);
int list_callback_return_type(int got); /* defined in list_builtin */


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


void hash_emit_new_container(int type):
	int key_type = type_set_key_type(type)
	char* fn_name = c"__w_set_new"
	if (type_is_map(type)):
		key_type = type_map_key_type(type)
		fn_name = c"__w_map_new"
	int s = rt_call_begin(fn_name)
	push_slot_int(hash_key_kind_for_type(key_type))
	if (type_is_map(type)):
		push_slot_int(type_get_size(type_map_value_type(type)))
	rt_call_end(s)


# Whether a 'new map[K, V](...)' default argument is a factory: a named
# function (type 4) or a value of fn-signature pointer type. Anything
# else is a stored default value.
int hash_default_is_factory(int got):
	if (got == 4):
		return 1
	return type_function_pointer_signature(type_real(got)) >= 0


# Whether the synthesized inner map of a 'new map[K, container]()' may
# default its own missing keys to a zero word: plain arithmetic scalars
# only. Pointer, string, var, struct and container values keep the trap
# (a zero word is not a usable default for any of them).
int hash_default_inner_zero(int value_type):
	int t = type_unqualified(value_type)
	if (type_is_map(t) | type_is_set(t) | type_is_list(t)):
		return 0
	if (type_num_args(t) > 0):
		return 0
	if (type_is_string(t)):
		return 0
	if (type_is_var(t)):
		return 0
	if (type_get_pointer_level(t) > 0):
		return 0
	return 1


# Packed descriptor for the synthesized empty-container default of
# 'new map[K, container]()'. The layout contract lives above
# __w_hash_default_container in structures/hash_table.w; the baked
# constants mirror hash_emit_new_container/list_emit_new_container.
int hash_default_container_descriptor(int value_type):
	int t = type_unqualified(value_type)
	if (type_is_list(t)):
		return 3 | (list_element_slot_size(type_list_element_type(t)) << 5)
	if (type_is_set(t)):
		return 2 | (hash_key_kind_for_type(type_set_key_type(t)) << 2)
	int desc = 1 | (hash_key_kind_for_type(type_map_key_type(t)) << 2)
	desc = desc | (type_get_size(type_map_value_type(t)) << 5)
	if (hash_default_inner_zero(type_map_value_type(t))):
		desc = desc | 16
	return desc


# Optional default for missing keys (issue #327): new map[K, V](arg)
# with the freshly-constructed map in eax and '(' not yet consumed. A
# map built without the argument list keeps the documented m[k] trap.
#   new map[K, V](value)     scalar V: every missing key reads as value
#   new map[K, V](factory)   zero-argument factory called per missing
#                            key (required for pointer/container V so
#                            vivified values never alias)
#   new map[K, container V]() synthesized empty-container factory; an
#                            inner map with arithmetic scalar values
#                            also defaults them to zero, so
#                            outer[a][b] += 1 works on a fresh 'a'.
#                            Deeper nesting needs explicit factories.
# The expression's value stays the map itself either way.
void hash_map_default_suffix(int type):
	if (accept(c"(") == 0):
		return;
	int container_type = type_unqualified(type)
	int value_type = type_map_value_type(container_type)
	if (type_num_args(value_type) > 0):
		error(c"map default does not support struct value types")
	int value_canonical = type_unqualified(value_type)
	int value_is_container = type_is_map(value_canonical) | type_is_set(value_canonical) | type_is_list(value_canonical)
	int base_stack = stack_pos
	int map_slot = push_slot()
	int default_kind = 0
	if (peek(c")")):
		if (value_is_container == 0):
			error(c"map default with no argument requires a container value type")
		default_kind = 3
		mov_eax_int(hash_default_container_descriptor(value_type))
	else:
		int got = expression()
		got = promote(got)
		if (hash_default_is_factory(got)):
			default_kind = 2
			int factory_return = list_callback_return_type(got)
			if (types_compatible_with_expression(value_type, factory_return) == 0):
				warn_type_mismatch(c"map default factory", value_type, factory_return)
		else:
			if (value_is_container | (type_get_pointer_level(value_canonical) > 0)):
				error(c"map default for a container or pointer value type must be a factory function")
			default_kind = 1
			coerce_checked(value_type, got, c"map default")
	expect(c")")
	int value_slot = push_slot()
	int s = rt_call_begin(c"__w_map_set_default")
	push_slot_copy(map_slot)
	push_slot_int(default_kind)
	push_slot_copy(value_slot)
	rt_call_end(s)
	load_slot(map_slot)
	pop_to(base_stack)


# Take the parked map and key slots (grammar/pending_element.w).
int* hash_pending_take():
	int* park = park_new(hash_index_base_stack, 2)
	park[2] = hash_index_map_slot
	park[3] = hash_index_key_slot
	hash_index_pending = 0
	return park


int hash_finish_pending_read():
	int value_type = type_map_value_type(hash_index_map_type)
	# Struct values are stored by value in the table; the read yields the
	# stored bytes' address, which is exactly how W passes structs around,
	# so the result keeps the struct's own (address-based) type. Reads
	# copy immediately; the address is only valid until the next insert.
	if (type_num_args(value_type) > 0):
		park_load(hash_pending_take(), c"__w_map_get_addr")
		return type_canonical(value_type)
	park_load(hash_pending_take(), c"__w_map_get")
	return type_value(value_type)


int hash_finish_pending_assignment():
	int value_type = type_map_value_type(hash_index_map_type)
	int* park = hash_pending_take()
	int got_type = parse_coerced(value_type, c"map assignment")
	int value_slot = push_slot()
	# Struct sources arrive as addresses; copy their bytes into the table
	char* fn = c"__w_map_set"
	if ((type_num_args(value_type) > 0) & (type_num_args(type_real(got_type)) > 0)):
		fn = c"__w_map_set_bytes"
	return park_store(park, fn, value_slot, value_type)


# m[key] op= rhs: the map and key already sit in the pending stack slots,
# so the read and the write reuse them and the key is evaluated exactly
# once. The read traps on a missing key, same as m[key] — unless the map
# was built with a 'new map[K, V](...)' default, in which case both
# vivify it (the policy lives inside __w_map_get, issue #327). 'op' is
# the marker compound_assign_op() returned; the op token is still pending.
int hash_finish_pending_compound(int op):
	int value_type = type_map_value_type(hash_index_map_type)
	int* park = hash_pending_take()
	if (type_num_args(value_type) > 0):
		error(c"compound assignment is not supported on struct values")
	if (type_is_buffer(type_canonical(value_type))):
		error(c"compound assignment is not supported on string, array or slice values")
	return park_compound(park, op, value_type, c"map assignment", c"__w_map_get", c"__w_map_set")


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
	int container_slot = push_slot()
	expect(c"(")
	int got_type = parse_coerced(key_type, context)
	expect(c")")
	int key_slot = push_slot()
	int s = rt_call_begin(fn_name)
	push_slot_copy(container_slot)
	push_slot_copy(key_slot)
	rt_call_end(s)
	pop_to(base_stack)


# m.free() / s.free(): 'free' has been consumed. Lowers to
# __w_map_free(container) — sets share the map layout, like remove.
# Frees the table's arrays, its cloned string keys and the header via
# the allocator the runtime used (lib/memory.w). Pointer VALUES are not
# chased: freeing pointed-to values stays the caller's job, exactly
# like lib/container.w's map_free[K, V]. Using the variable after
# free() is caller error, the same contract as lib/memory.w's free().
int hash_free_suffix(int type):
	promote(type)
	int base_stack = stack_pos
	int container_slot = push_slot()
	expect(c"(")
	expect(c")")
	int s = rt_call_begin(c"__w_map_free")
	push_slot_copy(container_slot)
	rt_call_end(s)
	pop_to(base_stack)
	return type_value(type_lookup(c"void"))


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
	int container_slot = push_slot()
	expect(c"(")
	int got_type = parse_coerced(key_type, c"map add key")
	int key_slot = push_slot()
	if (accept(c",")):
		int delta_got = parse_coerced(value_type, c"map add delta")
	else:
		mov_eax_int(1)
		if (value_kind):
			coerce(value_type, 3)
	expect(c")")
	int delta_slot = push_slot()
	int s = 0
	if (value_kind):
		# current = __w_map_get_or(map, key, 0): 0.0 when key is missing
		s = rt_call_begin(c"__w_map_get_or")
		push_slot_copy(container_slot)
		push_slot_copy(key_slot)
		push_slot_int(0)
		rt_call_end(s)
		# current + delta, same operand shape as compound_assign_apply:
		# left (current) into ebx, right (delta) reloaded into eax
		push_slot()
		load_slot(delta_slot)
		pop_ebx_slot()
		float_binary_arithmetic(type_value(value_type), type_value(value_type), '+')
		# store the sum back through the parked slots and yield it
		int sum_slot = push_slot()
		s = rt_call_begin(c"__w_map_set")
		push_slot_copy(container_slot)
		push_slot_copy(key_slot)
		push_slot_copy(sum_slot)
		rt_call_end(s)
		load_slot(sum_slot)
	else:
		s = rt_call_begin(c"__w_map_add")
		push_slot_copy(container_slot)
		push_slot_copy(key_slot)
		push_slot_copy(delta_slot)
		rt_call_end(s)
	pop_to(base_stack)
	return type_value(value_type)


# Shared lowering for m.keys()/s.keys()/m.values(): parses '()', calls
# fn_name(container, element_size) and returns list[element_type] with
# the snapshot's address in eax.
int hash_snapshot_list_suffix(int type, char* fn_name, int element_type):
	promote(type)
	int base_stack = stack_pos
	int container_slot = push_slot()
	expect(c"(")
	expect(c")")
	int s = rt_call_begin(fn_name)
	push_slot_copy(container_slot)
	push_slot_int(list_element_slot_size(type_canonical(element_type)))
	rt_call_end(s)
	pop_to(base_stack)
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
	int container_slot = push_slot()
	expect(c"(")
	int got_type = parse_coerced(key_type, c"map get key")
	int key_slot = push_slot()
	int has_default = 0
	int default_slot = 0
	if (accept(c",")):
		has_default = 1
		int default_got = parse_coerced(value_type, c"map get default")
		default_slot = push_slot()
	expect(c")")

	char* fn_name = c"__w_map_get"
	if (has_default):
		fn_name = c"__w_map_get_or"
		if (value_is_struct):
			fn_name = c"__w_map_get_or_addr"
	else if (value_is_struct):
		fn_name = c"__w_map_get_addr"
	int s = rt_call_begin(fn_name)
	push_slot_copy(container_slot)
	push_slot_copy(key_slot)
	if (has_default):
		push_slot_copy(default_slot)
	rt_call_end(s)

	pop_to(base_stack)
	if (value_is_struct):
		return type_canonical(value_type)
	return type_value(value_type)
