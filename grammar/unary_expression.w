int multiplicative_expr();
void zero_runtime_object(int bytes);
void init_array_field_descriptors(int type);
void assign_store_struct(int type); /* defined in expression */


# Store the constructor argument in eax into field field_index of the
# object whose address is saved on the stack. leaked_words counts stack
# words the argument's own expression left parked above that saved
# address (a struct-value argument parks its temp buffer there, issue
# #270), so the address is read esp-relative past the leak; the caller
# pops the leak afterwards. A struct-typed argument leaves the value's
# address in eax and is copied into the field like struct assignment;
# scalars store by the field's width. Out-of-range indexes emit
# nothing; the caller warns about the argument count.
void new_store_field(int base_type, int field_index, int arg_type, int leaked_words):
	if (field_index >= type_num_args(base_type)):
		return;
	int field_type = type_get_field_type_at(base_type, field_index)
	if (type_has_array_field(field_type)):
		error(c"cannot initialize fixed-array field in constructor")
	if (types_compatible_with_expression(field_type, arg_type) == 0):
		warn_type_mismatch(c"constructor argument", field_type, arg_type)
	coerce(field_type, arg_type)
	if (leaked_words > 0):
		mov_ebx_esp_plus(leaked_words << word_size_log2)
	else:
		mov_ebx_esp()
	add_ebx_int32(type_get_field_offset_at(base_type, field_index))
	if ((type_num_args(field_type) > 0) & (type_num_args(arg_type) > 0)):
		assign_store_struct(field_type)
		return;
	int field_size = type_get_size(field_type)
	if (field_size == 1):
		store_ebx_int8()
	else if (field_size == 2):
		store_ebx_int16()
	else if (field_size == 4):
		store_ebx_int32()
	else:
		store_ebx_word()


void zero_stack_count_bytes():
	int h_done = be_ctrl_block()
	int h_top = be_ctrl_loop()
	mov_eax_esp_plus(word_size)
	be_br_zero(h_done)
	mov_ebx_esp()
	mov_eax_int(0)
	store_ebx_int8()
	add_stack_word_int32(0, 1)
	add_stack_word_int32(word_size, -1)
	be_br(h_top)
	be_ctrl_end(h_top)
	be_ctrl_end(h_done)


# 'T(a, b)' where T names a struct or union type is a struct value
# constructor (issue #270): it builds the value in a stack temp and
# yields the temp's address, typed as a T value. Recognized by
# primary_expr before plain identifiers; the current token is the type
# name and nextc its '('. Type names shadow symbols here, matching the
# declaration grammar, and function-signature types are excluded so an
# alias like 'type cb = fn(int) -> int' never claims a call.
int struct_value_ctor_ready():
	if (nextc != '('):
		return 0
	int c = token[0]
	if (((('a' <= c) & (c <= 'z')) | (('A' <= c) & (c <= 'Z')) | (c == '_')) == 0):
		return 0
	int base = type_lookup(token)
	if (base < 0):
		return 0
	if (type_get_pointer_level(base) > 0):
		return 0
	if (type_is_function_signature(base)):
		return 0
	if (type_num_args(base) <= 0):
		return 0
	return 1


# Emit a struct value constructor expression. The temp stays parked on
# the stack (counted in stack_pos) exactly like a struct-returning
# call's return buffer, so every consumer that already handles by-value
# returns — argument sliding, assignment, declaration initializers, the
# 'new' constructor path — handles this the same way. Leaves the
# closing ')' as the current token for primary_expr's trailing
# get_token().
int struct_value_ctor_expr():
	int base = type_lookup(token)
	get_token()
	expect(c"(")
	int size = type_get_size(base)
	int words = (size + word_size - 1) >> word_size_log2
	int j = 0
	while (j < words):
		push_eax()
		j = j + 1
	stack_pos = stack_pos + words
	lea_eax_esp_plus(0)
	if (type_has_array_field(base)):
		zero_runtime_object(size)
		init_array_field_descriptors(base)
	# Park the temp's address below the buffer while the field
	# initializers run, mirroring the 'new' constructor path.
	push_eax()
	stack_pos = stack_pos + 1
	int field_index = 0
	if (peek(c")") == 0):
		int arg_entry = stack_pos
		int arg_type = expression()
		arg_type = promote(arg_type)
		new_store_field(base, 0, arg_type, stack_pos - arg_entry)
		if (stack_pos > arg_entry):
			be_pop(stack_pos - arg_entry)
			stack_pos = arg_entry
		field_index = 1
		while (accept(c",")):
			arg_type = expression()
			arg_type = promote(arg_type)
			new_store_field(base, field_index, arg_type, stack_pos - arg_entry)
			if (stack_pos > arg_entry):
				be_pop(stack_pos - arg_entry)
				stack_pos = arg_entry
			field_index = field_index + 1
		if (peek(c")") == 0):
			error(c"')' expected in constructor")
		if (field_index != type_num_args(base)):
			diag_part(c"warning: ")
			diag_part(type_get_name(base))
			diag_part(c" constructor expects ")
			diag_part(itoa(type_num_args(base)))
			diag_part(c" arguments, got ")
			warning(itoa(field_index))
	pop_eax()
	stack_pos = stack_pos - 1
	return type_value(base)


/*
unary-operator
& * + - ! ~

unary-expression
	postfix-expression
	unary-operator unary-expression

Unary operators bind tighter than any binary operator, so -a * b
means (-a) * b and unary operators can stack: !!a, -*p, *&x, ~-a.
*/
int unary_expression():
	int type
	if (accept(c"&")):
		type = unary_expression()
		# eax already holds the lvalue address; that address is the value here
		return 3 /* constant */
	else if (accept(c"*")):
		type = unary_expression()
		if (verbosity >= 1):
			print_error(itoa(line_number))
			print_error(c": unary * type: ")
			print_error(itoa(type))
			print_error(c", last symbol: ")
			print_error(last_global_declaration)
			print_error(c"\x0a")
		promote(type) /* load the pointer; eax becomes the element's address */
		if (type_get_pointer_level(type) > 0):
			return type_lookup_previous_pointer(type)
		return 1 /* deref of a plain int: word-sized lvalue */
	else if (accept(c"!!")):
		# The tokenizer scans "!!" as one token; it booleanizes like !(!x)
		type = unary_expression()
		promote(type)
		alu_test_set(0x95) /* setne */
		return type_value(bool_type)
	else if (accept(c"!")):
		type = unary_expression()
		promote(type)
		alu_test_set(0x94) /* sete */
		return type_value(bool_type)
	else if (accept(c"~")):
		type = unary_expression()
		type = promote(type)
		if (type_is_var(type_unqualified(type))):
			error(c"var operands do not support ~")
		if (type_float_kind(type)):
			error(c"float operands do not support ~")
		not_eax()
		return 3
	else if (accept(c"-")):
		type = unary_expression()
		type = promote(type)
		int kind = type_float_kind(type)
		if (kind == 1):
			# Avoid a high-bit literal here: x86 and x64 self-hosts parse it
			# with different signedness, but xor_eax_int32 only needs low bits.
			xor_eax_int32(1 << 31)
			return float32_value_type
		else if (kind == 2):
			btc_rax_63()
			return float64_value_type
		else:
			neg_eax()
			return 3
	else if (accept(c"+")):
		# unary plus: load the operand's value, no code beyond the promote
		type = unary_expression()
		type = promote(type)
		if (type_float_kind(type) == 2):
			return float64_value_type
		if (type_float_kind(type) == 1):
			return float32_value_type
		return 3
	else if (accept(c"cast")):
		expect(c"(")
		int want = type_name()
		expect(c",")
		int outer_cast = cast_context
		cast_context = 1
		type = expression()
		cast_context = outer_cast
		type = promote(type)
		if (type_num_args(want) > 0):
			error(c"cannot cast to a struct value")
		coerce_explicit(want, type)
		expect(c")")
		return type_value(want)
	else if (accept(c"new")):
		# new type-name — allocates sizeof(type) and yields a type*.
		# new type-name ( args ) also initializes the struct's fields from
		# the arguments in declaration order.
		if ((peek(c"map") & (nextc == '[')) | (peek(c"set") & (nextc == '['))):
			int container_type = type_name()
			hash_emit_new_container(container_type)
			return type_value(container_type)
		if (peek(c"list") & (nextc == '[')):
			int list_container_type = type_name()
			list_emit_new_container(list_container_type)
			return type_value(list_container_type)
		int base = type_lookup(token)
		if (base < 0):
			diag_part(c"unknown type after new: '")
			diag_part(token)
			error(c"'")
		get_token()
		if (accept(c"[")):
			int element_size = type_get_size(base)
			if (element_size <= 0):
				error(c"cannot allocate array of zero-sized type")
			int len_type = expression()
			promote(len_type)
			if (bounds_mode != 0):
				# eax = requested element count: trap through the
				# runtime helper unless 0 <= count <= the per-type
				# limit (issue #228). The trap block shuffles the
				# count into ebx and the limit into eax, the
				# bounds_trap_call convention; the in-bounds path
				# leaves eax untouched.
				int alloc_limit = 1073741823 / element_size
				int h_in_bounds = be_ctrl_block()
				int h_trap = be_ctrl_block()
				bounds_branch_eax_negative(h_trap)
				bounds_skip_eax_less_equal_int32(alloc_limit, h_in_bounds)
				be_ctrl_end(h_trap)
				push_eax()
				mov_eax_int(alloc_limit)
				pop_ebx()
				bounds_trap_call(c"__w_alloc_trap")
				be_ctrl_end(h_in_bounds)
			expect(c"]")
			push_eax()
			stack_pos = stack_pos + 1

			# malloc(2 * word_size + length * sizeof(base))
			sym_get_value(c"malloc")
			push_eax()
			stack_pos = stack_pos + 1
			mov_eax_esp_plus(word_size)
			if (element_size > 1):
				imul_eax_int32(element_size)
			add_eax_int32(2 * word_size)
			push_eax()
			stack_pos = stack_pos + 1
			mov_eax_esp_plus(word_size)
			call_eax()
			be_pop(2)
			stack_pos = stack_pos - 2

			# descriptor.data = descriptor + header
			push_eax()
			stack_pos = stack_pos + 1
			add_eax_int32(2 * word_size)
			mov_ebx_esp()
			store_ebx_word()

			# descriptor.length = saved length
			mov_eax_esp_plus(word_size)
			mov_ebx_esp()
			add_ebx_int32(word_size)
			store_ebx_word()

			# Zero the payload so new arrays have deterministic contents.
			mov_eax_esp_plus(word_size)
			if (element_size > 1):
				imul_eax_int32(element_size)
			push_eax()
			stack_pos = stack_pos + 1
			mov_eax_esp_plus(word_size)
			add_eax_int32(2 * word_size)
			push_eax()
			stack_pos = stack_pos + 1
			zero_stack_count_bytes()
			be_pop(2)
			stack_pos = stack_pos - 2

			pop_eax()
			stack_pos = stack_pos - 1
			be_pop(1)
			stack_pos = stack_pos - 1
			return type_get_slice_value(base)

		int has_parens = accept(c"(")

		# malloc(size), using the same callee-first stack layout as postfix calls
		sym_get_value(c"malloc")
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_int(type_get_size(base))
		push_eax()
		stack_pos = stack_pos + 1
		mov_eax_esp_plus(1 << word_size_log2)
		call_eax()
		be_pop(2)
		stack_pos = stack_pos - 2
		if (type_has_array_field(base)):
			zero_runtime_object(type_get_size(base))
			init_array_field_descriptors(base)

		if (has_parens):
			if (accept(c")") == 0):
				# Constructor arguments: keep the allocation address on the
				# stack while each argument expression runs, storing every
				# result into its field. An argument that parks a temp on
				# the stack (a struct-value constructor or a
				# struct-returning call) buries the saved address; the
				# store reads it esp-relative and the leak is popped so
				# the next argument sees the address on top again.
				push_eax()
				stack_pos = stack_pos + 1
				int arg_entry = stack_pos
				int arg_type = expression()
				arg_type = promote(arg_type)
				new_store_field(base, 0, arg_type, stack_pos - arg_entry)
				if (stack_pos > arg_entry):
					be_pop(stack_pos - arg_entry)
					stack_pos = arg_entry
				int field_index = 1
				while (accept(c",")):
					arg_type = expression()
					arg_type = promote(arg_type)
					new_store_field(base, field_index, arg_type, stack_pos - arg_entry)
					if (stack_pos > arg_entry):
						be_pop(stack_pos - arg_entry)
						stack_pos = arg_entry
					field_index = field_index + 1
				expect(c")")
				if (field_index != type_num_args(base)):
					diag_part(c"warning: new ")
					diag_part(type_get_name(base))
					diag_part(c" expects ")
					diag_part(itoa(type_num_args(base)))
					diag_part(c" arguments, got ")
					warning(itoa(field_index))
				pop_eax()
				stack_pos = stack_pos - 1

		# eax holds the allocation's address; the expression's type is the
		# pointer to the allocated type, so mismatched stores warn.
		return type_value(type_get_next_pointer(base))
	else:
		return postfix_expr()
