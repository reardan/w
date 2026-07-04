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


int list_literal_type


void list_emit_new_container(int type):
	sym_get_value(c"__w_list_new")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_int(type_get_size(type_list_element_type(type)))
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
# asserts the list is non-empty and returns the removed element.
int list_pop_suffix(int type):
	int element_type = type_list_element_type(type_unqualified(type))
	promote(type)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int list_slot = stack_pos
	expect(c"(")
	expect(c")")
	sym_get_value(c"__w_list_pop")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(list_slot)
	hash_call_finish(s)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(element_type)


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
