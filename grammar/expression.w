# Set whenever an expression performs an assignment. Only the REPL reads
# it (to suppress echoing "x = 5"); it clears the flag before each entry.
int expression_is_assignment


# Store eax through the address in ebx, sized by the left-hand side's type.
void assign_store(int type):
	type = type_canonical(type)
	int lhs_size = word_size
	if ((type_get_pointer_level(type) == 0) & (type != 3) & (type != 4)):
		int declared_size = type_get_size(type)
		if (declared_size > 0):
			lhs_size = declared_size
	if (lhs_size == 1):
		store_ebx_int8()
	else if (lhs_size == 2):
		store_ebx_int16()
	else if (lhs_size == 4):
		store_ebx_int32()
	else:
		store_ebx_word()


void assign_store_struct(int type):
	int words = (type_get_size(type) + word_size - 1) >> word_size_log2
	push_ebx()
	stack_pos = stack_pos + 1
	push_eax()
	stack_pos = stack_pos + 1
	int i = 0
	while (i < words):
		mov_eax_esp_plus(0)
		if (i > 0):
			add_eax_int32(i << word_size_log2)
		promote_eax()
		if (i > 0):
			add_ebx_int32(word_size)
		store_ebx_word()
		i = i + 1
	pop_eax()
	stack_pos = stack_pos - 1
	pop_ebx()
	stack_pos = stack_pos - 1
	if (type_has_array_field(type)):
		mov_eax_ebx()
		init_array_field_descriptors(type)


# Compound assignment: return the underlying operator for the current
# token ('+' for '+=', ..., 'l' for '<<=', 'r' for '>>='), or 0 when the
# token is not a compound assignment operator.
int compound_assign_op():
	if (peek(c"+=")):
		return '+'
	if (peek(c"-=")):
		return '-'
	if (peek(c"*=")):
		return '*'
	if (peek(c"/=")):
		return '/'
	if (peek(c"%=")):
		return '%'
	if (peek(c"&=")):
		return '&'
	if (peek(c"|=")):
		return '|'
	if (peek(c"^=")):
		return '^'
	if (peek(c"<<=")):
		return 'l'
	if (peek(c">>=")):
		return 'r'
	return 0


# Lower the operator of 'lhs op= rhs': the loaded left value sits on top
# of the stack and eax holds the promoted right value. Emits the same code
# as the corresponding binary operator, leaves the result in eax and
# returns its expression type; the stack drops by one word.
int compound_assign_apply(int op, int left_type, int right_type):
	if ((op == '/') | (op == '%') | (op == 'l') | (op == 'r')):
		if (binary_float_kind(left_type, right_type)):
			if (op == '/'):
				pop_ebx()
				stack_pos = stack_pos - 1
				return float_binary_arithmetic(left_type, right_type, '/')
			error(c"float operands only support += -= *= /=")
		if (op == '/'):
			alu_idiv()
		else if (op == '%'):
			alu_imod()
		else if (op == 'l'):
			alu_shl()
		else:
			alu_sar()
		stack_pos = stack_pos - 1
		return 3
	pop_ebx()
	stack_pos = stack_pos - 1
	if ((op == '+') | (op == '-') | (op == '*')):
		int result_type = float_binary_arithmetic(left_type, right_type, op)
		if (result_type):
			return result_type
	if (binary_float_kind(left_type, right_type)):
		error(c"float operands only support += -= *= /=")
	if (op == '+'):
		alu_add()
	else if (op == '-'):
		alu_sub()
	else if (op == '*'):
		alu_imul()
	else if (op == '&'):
		alu_and()
	else if (op == '|'):
		alu_or()
	else:
		alu_xor()
	return 3


/*
 * expression:
 *         logical-or-expr
 *         logical-or-expr = expression
 *         logical-or-expr op= expression
 */
int expression():
	expression_lhs_readonly = 0
	int type = logical_or_expr()
	if (hash_index_pending):
		if (accept(c"=")):
			expression_is_assignment = 1
			return hash_finish_pending_assignment()
		if (compound_assign_op()):
			error(c"compound assignment is not supported on map or set index targets")
		type = hash_finish_pending_read()
	int op = compound_assign_op()
	if (op):
		get_token()
		if (expression_lhs_readonly):
			error(c"cannot assign to read-only buffer field")
		if ((type_is_value(type)) | (type == 3) | (type == 4)):
			error(c"assignment target is not assignable")
		if (type_is_const(type)):
			error(c"assignment to const")
		if (type_num_args(type_canonical(type)) > 0):
			error(c"compound assignment is not supported on struct values")
		if (type_is_buffer(type_canonical(type))):
			error(c"compound assignment is not supported on string, array or slice values")
		expression_is_assignment = 1
		expression_lhs_readonly = 0
		push_eax()  # lhs address, kept for the final store
		stack_pos = stack_pos + 1
		int left_type = promote(type)  # eax still holds the address: load
		push_eax()
		stack_pos = stack_pos + 1
		int right_type = promote(expression())
		if (var_binary_operands(left_type, right_type)):
			error(c"compound assignment does not support var operands")
		int result_type = compound_assign_apply(op, left_type, right_type)
		coerce(type, result_type)
		pop_ebx()
		stack_pos = stack_pos - 1
		if (types_compatible_with_expression(type, result_type) == 0):
			warn_type_mismatch(c"assignment", type, result_type)
		assign_store(type)
		return type_value(type)  # like '=', yields the stored value
	if (accept(c"=")):
		if (expression_lhs_readonly):
			error(c"cannot assign to read-only buffer field")
		if ((type_is_value(type)) | (type == 3) | (type == 4)):
			error(c"assignment target is not assignable")
		if (type_is_const(type)):
			error(c"assignment to const")
		expression_is_assignment = 1
		expression_lhs_readonly = 0
		push_eax()
		stack_pos = stack_pos + 1
		int lhs_slot = stack_pos
		int type2 = expression()
		if (verbosity >= 1):
			print2(c"expression() type: ")
			type_print(type)
			print_int(c"expression() type: ", type)
			print_int(c"expression() type2: ", type2)
		
		type2 = promote(type2)
		coerce(type, type2)
		# A struct-returning call on the right side parks its return
		# buffer on the stack (eax points into it), burying the saved
		# lhs address; read it esp-relative instead of popping. The
		# saved word and the buffer stay counted in stack_pos, so the
		# enclosing statement's cleanup pops them.
		int lhs_buried = stack_pos - lhs_slot
		if (lhs_buried > 0):
			mov_ebx_esp_plus(lhs_buried << word_size_log2)
		else:
			pop_ebx()

		# Warn when the two sides carry conflicting types; constants (3) and
		# functions (4) act as wildcards inside types_compatible().
		if (types_compatible_with_expression(type, type2) == 0):
			warn_type_mismatch(c"assignment", type, type2)

		# Struct assignment copies the aggregate; scalar stores use lhs width.
		if ((type_num_args(type) > 0) & (type_num_args(type2) > 0)):
			assign_store_struct(type)
		else:
			assign_store(type)

		if (lhs_buried == 0):
			stack_pos = stack_pos - 1

		type = type_value(type)  # assignment yields the stored value

	return type
