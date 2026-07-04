int expression();
int hash_literal_type


void hash_literal_call_map_set(int container_slot, int key_slot, int value_slot):
	sym_get_value(c"__w_map_set")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(container_slot)
	hash_push_stack_slot(key_slot)
	hash_push_stack_slot(value_slot)
	hash_call_finish(s)


void hash_literal_call_set_add(int container_slot, int key_slot):
	sym_get_value(c"__w_set_add")
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(container_slot)
	hash_push_stack_slot(key_slot)
	hash_call_finish(s)


void hash_literal_parse_map_entry(int container_type, int container_slot):
	int base_stack = stack_pos
	int key_type = type_map_key_type(container_type)
	int value_type = type_map_value_type(container_type)
	int got_key_type = expression()
	got_key_type = promote(got_key_type)
	coerce(key_type, got_key_type)
	if (types_compatible_with_expression(key_type, got_key_type) == 0):
		warn_type_mismatch(c"map literal key", key_type, got_key_type)
	push_eax()
	stack_pos = stack_pos + 1
	int key_slot = stack_pos
	expect(c":")
	int got_value_type = expression()
	got_value_type = promote(got_value_type)
	coerce(value_type, got_value_type)
	if (types_compatible_with_expression(value_type, got_value_type) == 0):
		warn_type_mismatch(c"map literal value", value_type, got_value_type)
	push_eax()
	stack_pos = stack_pos + 1
	int value_slot = stack_pos
	hash_literal_call_map_set(container_slot, key_slot, value_slot)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack


void hash_literal_parse_set_entry(int container_type, int container_slot):
	int base_stack = stack_pos
	int key_type = type_set_key_type(container_type)
	int got_key_type = expression()
	got_key_type = promote(got_key_type)
	coerce(key_type, got_key_type)
	if (types_compatible_with_expression(key_type, got_key_type) == 0):
		warn_type_mismatch(c"set literal key", key_type, got_key_type)
	push_eax()
	stack_pos = stack_pos + 1
	int key_slot = stack_pos
	hash_literal_call_set_add(container_slot, key_slot)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack


int hash_typed_literal():
	if (((peek(c"map") & (nextc == '[')) == 0) & ((peek(c"set") & (nextc == '[')) == 0)):
		return 0
	int container_type = type_name()
	if ((type_is_map(container_type) == 0) & (type_is_set(container_type) == 0)):
		return 0
	expect(c"{")
	hash_emit_new_container(container_type)
	push_eax()
	stack_pos = stack_pos + 1
	int container_slot = stack_pos
	if (peek(c"}") == 0):
		if (type_is_map(container_type)):
			hash_literal_parse_map_entry(container_type, container_slot)
		else:
			hash_literal_parse_set_entry(container_type, container_slot)
		while (accept(c",")):
			if (peek(c"}")):
				break
			if (type_is_map(container_type)):
				hash_literal_parse_map_entry(container_type, container_slot)
			else:
				hash_literal_parse_set_entry(container_type, container_slot)
	if (peek(c"}") == 0):
		error(c"'}' expected in hash literal")
	pop_eax()
	stack_pos = stack_pos - 1
	hash_literal_type = type_value(container_type)
	return 1

/*
 * primary-expr:
 *     identifier
 *     constant
 *     ( expression )
 */
int primary_expr():
	int type
	int new_type
	# Float literal (must run before int_literal, which only checks the first
	# character before decoding the whole token)
	int literal_type = float_literal()
	if (literal_type):
		type = literal_type

	# Bool literals
	else if (peek(c"true")):
		mov_eax_int(1)
		type = type_value(bool_type)

	else if (peek(c"false")):
		mov_eax_int(0)
		type = type_value(bool_type)

	# Integer literal
	else if (int_literal()):
		type = 3 /* constant */

	# Compile-time constant: the target's word size in bytes (4 or 8),
	# baked in when the enclosing file is compiled
	else if (peek(c"__word_size__")):
		mov_eax_int(word_size)
		type = 3 /* constant */

	else if (utf8_string_literal()):
		type = string_value_type

	else if (c_char_pointer_literal()):
		type = type_value(type_lookup_pointer(c"char", 1))

	else if (hash_typed_literal()):
		type = hash_literal_type

	else if (list_typed_literal()):
		type = list_literal_type

	# Identifier
	else if ((new_type = identifier()) >= 0) {
		type = new_type
	}
	# ( expression )
	else if (accept(c"(")) {
		type = expression()
		if (peek(c")") == 0):
			error(c"No closing parenthesis")
	}
	# char literal e.g. 'c'
	else if ((token[0] == 39) & (token[1] != 0) &
					 (token[2] == 39) & (token[3] == 0)):
		mov_eax_int(token[1])
		type = 3 /* constant */

	# escaped char literal e.g. '\n'
	else if ((token[0] == 39) & (token[1] == 92) &
					 (token[3] == 39) & (token[4] == 0)):
		int c = token[2]
		if (c == 'n'):
			c = 10
		else if (c == 't'):
			c = 9
		else if (c == 'r'):
			c = 13
		else if (c == '0'):
			c = 0
		mov_eax_int(c)
		type = 3 /* constant */

	else if (char_pointer_literal()):
		type = string_value_type

	else:
		print2(c"Could not find a valid primary expression, token: ")
		error(token)

	get_token()
	return type
