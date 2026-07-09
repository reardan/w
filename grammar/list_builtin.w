/*
Compiler lowering for the built-in typed list[T] container.

new list[T], list[T]{...} literals, l[index], the push/pop pseudo-methods
and .length lower to the __w_list_* runtime helpers in structures/w_list.w
(auto-imported into every program). l[index] calls __w_list_addr and
leaves the element's ADDRESS in eax, so element reads and writes flow
through the normal lvalue machinery with the element type's own width; no
pending-lvalue state is needed, unlike map indexing.

The call emission reuses the callee-first stack layout helpers from
grammar/hash_builtin.w (hash_push_stack_slot, hash_call_finish).
*/
int expression();
int inferred_storage_type(int got); /* defined in variable_declaration */


int list_literal_type


# Bytes per element slot. Struct slots round up to a word multiple so W's
# word-granular struct copies stay inside the element's storage.
int list_element_slot_size(int element_type):
	if (type_num_args(element_type) > 0):
		return type_stack_words(element_type) << word_size_log2
	return type_get_size(element_type)


void list_emit_new_container(int type):
	sym_get_value(c"__w_list_new")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_int(list_element_slot_size(type_list_element_type(type)))
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)


# l[index]: '[' has been consumed and the list lvalue or value is in eax.
# Evaluates the index, calls __w_list_addr(list, index) and returns the
# element type with the element's address in eax (a normal lvalue).
int list_index_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	# promote before anchoring base_stack: finishing a pending map read
	# (e.g. table[key][0]) pops the read's hidden stack slots
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	promote(expression())
	expect(c"]")
	push_eax()
	stack_pos = stack_pos + 1
	int index_slot = stack_pos
	sym_get_value(c"__w_list_addr")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(index_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return element_type


# l.push(value): 'push' has been consumed. Parses '(value)', checks and
# coerces the value against the element type and lowers to
# __w_list_push(list, value).
int list_push_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	int got_type = expression()
	got_type = promote(got_type)
	coerce(element_type, got_type)
	if (types_compatible_with_expression(element_type, got_type) == 0):
		warn_type_mismatch(c"list push", element_type, got_type)
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	# Struct sources arrive as addresses; copy their bytes into the slot
	if ((type_num_args(element_type) > 0) & (type_num_args(type_real(got_type)) > 0)):
		sym_get_value(c"__w_list_push_bytes")
	else:
		sym_get_value(c"__w_list_push")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup(c"void"))


# l.pop(): 'pop' has been consumed. Lowers to __w_list_pop(list), which
# asserts the list is non-empty and returns the removed element. Struct
# elements come back as the removed slot's address (valid until the next
# push), so the caller's copy semantics match other struct values.
int list_pop_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	expect(c")")
	if (type_num_args(element_type) > 0):
		sym_get_value(c"__w_list_pop_addr")
	else:
		sym_get_value(c"__w_list_pop")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(element_type)


# l.remove(index): 'remove' has been consumed. Lowers to
# __w_list_remove(list, index), which shifts the tail left.
int list_remove_suffix(int type):
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	promote(expression())
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int index_slot = stack_pos
	sym_get_value(c"__w_list_remove")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(index_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup(c"void"))


# l.insert(index, value): 'insert' has been consumed. Checks the value
# against the element type and lowers to __w_list_insert(list, index, value).
int list_insert_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	promote(expression())
	push_eax()
	stack_pos = stack_pos + 1
	int index_slot = stack_pos
	expect(c",")
	int got_type = expression()
	got_type = promote(got_type)
	coerce(element_type, got_type)
	if (types_compatible_with_expression(element_type, got_type) == 0):
		warn_type_mismatch(c"list insert", element_type, got_type)
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	# Struct sources arrive as addresses; copy their bytes into the slot
	if ((type_num_args(element_type) > 0) & (type_num_args(type_real(got_type)) > 0)):
		sym_get_value(c"__w_list_insert_bytes")
	else:
		sym_get_value(c"__w_list_insert")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(index_slot)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup(c"void"))


# l.clear(): 'clear' has been consumed. Lowers to __w_list_clear(list).
int list_clear_suffix(int type):
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	expect(c")")
	sym_get_value(c"__w_list_clear")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup(c"void"))


# Element comparison kind for sort/count/index: 1 signed word compare,
# 2 char* contents (the map/set key rule). Aggregates, strings, floats
# and containers have no built-in ordering and are rejected.
int list_scalar_kind(int element_type, char* what):
	int t = type_unqualified(element_type)
	if ((type_num_args(t) > 0) | type_is_string(t) | (type_float_kind(t) != 0) |
			type_is_map(t) | type_is_set(t) | type_is_list(t) |
			type_is_array(t) | type_is_slice(t)):
		diag_part(c"list ")
		diag_part(what)
		diag_part(c" requires int-like or char* elements, got '")
		print_error_type(element_type)
		error(c"'")
	return hash_key_kind_for_type(t)


# map/filter/reduce pass elements to the callback as word values, so
# aggregate elements (copied by address) are out.
void list_require_scalar_elements(int element_type, char* what):
	int t = type_unqualified(element_type)
	if ((type_num_args(t) > 0) | type_is_string(t) |
			type_is_array(t) | type_is_slice(t)):
		diag_part(c"list ")
		diag_part(what)
		diag_part(c" requires scalar elements, got '")
		print_error_type(element_type)
		error(c"'")


# Callback arguments must be a named function (type 4) or a value
# holding a function address (fn alias pointers included).
void list_check_callback(int got, char* what):
	if (got == 4):
		return;
	if (type_get_pointer_level(type_real(got)) > 0):
		return;
	diag_part(c"list ")
	diag_part(what)
	diag_part(c" expects a function, got '")
	print_error_type(got)
	error(c"'")


# Declared return type of the callback just parsed (type in got, its
# address in eax): a named function's symbol-table return type, or the
# fn signature's return type for typed pointers. Unknown callees (plain
# int*/asm stubs) default to int.
int list_callback_return_type(int got):
	if (got == 4):
		int callee = sym_lookup(last_identifier)
		if (callee >= 0):
			int declared = load_int(table + callee + 6)
			if ((declared >= 0) & (declared != 4)):
				return type_unqualified(declared)
		return type_lookup(c"int")
	int sig = type_function_pointer_signature(type_real(got))
	if (sig >= 0):
		return type_unqualified(type_function_return(sig))
	return type_lookup(c"int")


# l.sort(): 'sort' has been consumed. In-place ascending insertion sort;
# int-like elements compare as signed words, char* elements by contents.
int list_sort_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	int kind = list_scalar_kind(element_type, c"sort")
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	expect(c")")
	sym_get_value(c"__w_list_sort")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	mov_eax_int(kind)
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup(c"void"))


# l.sort_by(f): 'sort_by' has been consumed. f returns negative/zero/
# positive like strcmp. Scalar elements pass values to f; aggregate
# elements pass element addresses.
int list_sort_by_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	int is_aggregate = type_num_args(type_unqualified(element_type)) > 0
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	int got = expression()
	got = promote(got)
	list_check_callback(got, c"sort_by")
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int fn_slot = stack_pos
	if (is_aggregate):
		sym_get_value(c"__w_list_sort_by_addr")
	else:
		sym_get_value(c"__w_list_sort_by")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(fn_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup(c"void"))


# l.map(f): 'map' has been consumed. Returns a NEW list whose element
# type is f's declared return type.
int list_map_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	list_require_scalar_elements(element_type, c"map")
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	int got = expression()
	got = promote(got)
	list_check_callback(got, c"map")
	int result_element = list_callback_return_type(got)
	list_require_scalar_elements(result_element, c"map result")
	if (type_get_size(result_element) == 0):
		error(c"list map callback must return a value")
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int fn_slot = stack_pos
	sym_get_value(c"__w_list_map")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(fn_slot)
	mov_eax_int(list_element_slot_size(result_element))
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_get_list(type_canonical(result_element)))


# l.filter(f): 'filter' has been consumed. Returns a NEW list of the
# same element type holding the elements where f(x) is true.
int list_filter_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	list_require_scalar_elements(element_type, c"filter")
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	int got = expression()
	got = promote(got)
	list_check_callback(got, c"filter")
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int fn_slot = stack_pos
	sym_get_value(c"__w_list_filter")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(fn_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_get_list(type_canonical(element_type)))


# l.reduce(f, init): 'reduce' has been consumed. Left fold; the result
# type is the init expression's type.
int list_reduce_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	list_require_scalar_elements(element_type, c"reduce")
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	int got = expression()
	got = promote(got)
	list_check_callback(got, c"reduce")
	push_eax()
	stack_pos = stack_pos + 1
	int fn_slot = stack_pos
	expect(c",")
	int got_init = expression()
	got_init = promote(got_init)
	int result_type = inferred_storage_type(got_init)
	if (type_num_args(result_type) > 0):
		error(c"list reduce init must be a scalar value")
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int init_slot = stack_pos
	sym_get_value(c"__w_list_reduce")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(fn_slot)
	hash_push_stack_slot(init_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(result_type)


# Shared lowering for the no-argument aggregations: sum, min and max.
int list_aggregate_suffix(int type, char* helper_name, char* what, int result_type):
	int element_type = type_list_element_type(type_unqualified(type))
	int kind = list_scalar_kind(element_type, what)
	if (kind != 1):
		diag_part(c"list ")
		diag_part(what)
		error(c" requires int-like elements")
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	expect(c")")
	sym_get_value(helper_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(result_type)


# l.reverse(): 'reverse' has been consumed. In-place, any element type.
int list_reverse_suffix(int type):
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	expect(c")")
	sym_get_value(c"__w_list_reverse")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup(c"void"))


# Shared lowering for l.count(x) and l.index(x): the value coerces to
# the element type; char* elements compare by contents.
int list_scan_suffix(int type, char* helper_name, char* what):
	int element_type = type_list_element_type(type_unqualified(type))
	int kind = list_scalar_kind(element_type, what)
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	int got = expression()
	got = promote(got)
	coerce(element_type, got)
	if (types_compatible_with_expression(element_type, got) == 0):
		warn_type_mismatch(what, element_type, got)
	expect(c")")
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	sym_get_value(helper_name)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_push_stack_slot(value_slot)
	mov_eax_int(kind)
	push_eax()
	stack_pos = stack_pos + 1
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_lookup(c"int"))


void list_literal_parse_entry(int container_type, int container_slot):
	int base_stack = stack_pos
	int element_type = type_list_element_type(container_type)
	int got_type = expression()
	got_type = promote(got_type)
	coerce(element_type, got_type)
	if (types_compatible_with_expression(element_type, got_type) == 0):
		warn_type_mismatch(c"list literal element", element_type, got_type)
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	if ((type_num_args(element_type) > 0) & (type_num_args(type_real(got_type)) > 0)):
		sym_get_value(c"__w_list_push_bytes")
	else:
		sym_get_value(c"__w_list_push")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(container_slot)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack


int list_typed_literal():
	if ((peek(c"list") & (nextc == '[')) == 0):
		return 0
	int container_type = type_name()
	expect(c"{")
	list_emit_new_container(container_type)
	push_eax()
	stack_pos = stack_pos + 1
	int container_slot = stack_pos
	if (peek(c"}") == 0):
		list_literal_parse_entry(container_type, container_slot)
		while (accept(c",")):
			if (peek(c"}")):
				break
			list_literal_parse_entry(container_type, container_slot)
	if (peek(c"}") == 0):
		error(c"'}' expected in list literal")
	pop_eax()
	stack_pos = stack_pos - 1
	list_literal_type = type_value(container_type)
	return 1
