int multiplicative_expr();
void zero_runtime_object(int bytes);
void init_array_field_descriptors(int type);


# Store the constructor argument in eax into field field_index of the
# allocation whose address sits on top of the stack. Out-of-range
# indexes emit nothing; the caller warns about the argument count.
void new_store_field(int base_type, int field_index, int arg_type):
	if (field_index >= type_num_args(base_type)):
		return;
	int field_type = type_get_field_type_at(base_type, field_index)
	if (type_has_array_field(field_type)):
		error(c"cannot initialize fixed-array field in constructor")
	if (types_compatible_with_expression(field_type, arg_type) == 0):
		warn_type_mismatch(c"constructor argument", field_type, arg_type)
	coerce(field_type, arg_type)
	mov_ebx_esp()
	add_ebx_int32(type_get_field_offset_at(base_type, field_index))
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
	int loop_start = codepos
	mov_eax_esp_plus(word_size)
	jmp_zero_int32(0)
	int done_patch = codepos
	mov_ebx_esp()
	mov_eax_int(0)
	store_ebx_int8()
	add_stack_word_int32(0, 1)
	add_stack_word_int32(word_size, -1)
	jmp_int32(0)
	be_branch_patch(codepos, loop_start)
	be_branch_patch(done_patch, codepos)


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
		type = expression()
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
			print2(c"unknown type after new: '")
			print2(token)
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
				int negative_site = bounds_branch_eax_negative()
				int in_bounds_site = bounds_skip_eax_less_equal_int32(alloc_limit)
				be_branch_patch(negative_site, codepos)
				push_eax()
				mov_eax_int(alloc_limit)
				pop_ebx()
				bounds_trap_call(c"__w_alloc_trap")
				be_branch_patch(in_bounds_site, codepos)
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
				# result into its field.
				push_eax()
				stack_pos = stack_pos + 1
				int arg_type = expression()
				arg_type = promote(arg_type)
				new_store_field(base, 0, arg_type)
				int field_index = 1
				while (accept(c",")):
					arg_type = expression()
					arg_type = promote(arg_type)
					new_store_field(base, field_index, arg_type)
					field_index = field_index + 1
				expect(c")")
				if (field_index != type_num_args(base)):
					print_error(str_from_cstr(c"warning: new "))
					print_error(str_from_cstr(type_get_name(base)))
					print_error(str_from_cstr(c" expects "))
					print_error(str_from_cstr(itoa(type_num_args(base))))
					print_error(str_from_cstr(c" arguments, got "))
					warning(itoa(field_index))
				pop_eax()
				stack_pos = stack_pos - 1

		# eax holds the allocation's address; the expression's type is the
		# pointer to the allocated type, so mismatched stores warn.
		return type_value(type_get_next_pointer(base))
	else:
		return postfix_expr()
