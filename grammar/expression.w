# Set whenever an expression performs an assignment. Only the REPL reads
# it (to suppress echoing "x = 5"); it clears the flag before each entry.
int expression_is_assignment


# Store eax through the address in ebx, sized by the left-hand side's type.
void assign_store(int type):
	# A 'gpu T*' element: rejected in host code, st.global on device
	# (the promote() twin in grammar/promote.w)
	if (type_is_gpu_object(type)):
		gpu_host_access_check(type)
		ptx_global_access = 1
		assign_store(type_strip_gpu(type))
		ptx_global_access = 0
		return;
	type = type_canonical(type)
	# An imported C bit-field member: ebx addresses its storage unit;
	# read-modify-write it (grammar/promote.w, bit_field_assign_store)
	if (ci_is_bit_field_access(type)):
		bit_field_assign_store(type)
		return;
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


# Copy the struct at eax into the struct at ebx, word by word, then
# rebuild any inline array-field descriptors in the destination.
void struct_copy_eax_to_ebx(int type):
	int words = (type_get_size(type) + word_size - 1) >> word_size_log2
	push_ebx()
	stack_pos = stack_pos + 1
	push_slot()
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
	pop_eax_slot()
	pop_ebx_slot()
	if (type_has_array_field(type)):
		mov_eax_ebx()
		init_array_field_descriptors(type)


void assign_store_struct(int type):
	gpu_host_access_check(type)
	struct_copy_eax_to_ebx(type)


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
	if ((op == '/') || (op == '%') || (op == 'l') || (op == 'r')):
		if (binary_float_kind(left_type, right_type)):
			if (op == '/'):
				pop_ebx_slot()
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
	pop_ebx_slot()
	if ((op == '+') || (op == '-') || (op == '*')):
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
 *         conditional-expr
 *         conditional-expr = expression
 *         conditional-expr op= expression
 */
int expression():
	int stmt_context = increment_statement_context
	increment_statement_context = 0
	expression_lhs_readonly = 0
	# 'w check --lint' (compiler/lint.w): a single-token left side and
	# where its '=' sits, for self-assign and assign-in-condition
	int lhs_serial = token_serial
	int type = conditional_expr()
	int lhs_tokens = token_serial - lhs_serial
	int eq_line = diag_token_line
	int eq_column = diag_token_column
	int inc_op = increment_op()
	if (token_newline):
		# A '++'/'--' on the NEXT line is that statement's own prefix
		# operator, not a postfix of this expression — a newline ends
		# the statement here exactly like it does for expect_or_newline.
		inc_op = 0
	if (inc_op):
		# Postfix '++'/'--' bind only at true statement position (the
		# flag set by statement()'s expression fallback); anywhere else
		# the v1 statement-only rule makes them an error
		# (grammar/increment.w, docs/projects/increment_decrement.md).
		if (stmt_context == 0):
			increment_expression_error()
		get_token()
		expression_is_assignment = 1
		return increment_apply(inc_op, type)
	# 'lv1, lv2[, ...] = e1, e2[, ...]' parallel assignment
	# (grammar/multi_assign.w) claims a ',' after the first lvalue only
	# at true statement position — the same flag discipline as the
	# postfix '++' above, so a ',' inside call arguments, case labels
	# or conditions still belongs to the enclosing construct. Checked
	# before the pending-map block so a map-element target gets multi-
	# assign's own rejection instead of resolving into a read.
	if (stmt_context && (token_newline == 0)):
		if (peek(c",")):
			expression_is_assignment = 1
			return multi_assign(type)
	# A pending map element (grammar/hash_builtin.w) or ndarray element
	# (grammar/ndarray_index.w, grammar/pending_element.w): '=' lowers
	# to its store, a compound operator to the read/write pair over the
	# parked operands, anything else to the read.
	if (hash_index_pending || nd_index_pending):
		if (accept(c"=")):
			expression_is_assignment = 1
			if (hash_index_pending):
				return hash_finish_pending_assignment()
			return nd_finish_pending_assignment()
		int pending_op = compound_assign_op()
		if (pending_op):
			get_token()
			expression_is_assignment = 1
			if (hash_index_pending):
				return hash_finish_pending_compound(pending_op)
			return nd_finish_pending_compound(pending_op)
		type = hash_finalize_pending_read_if_needed(type)
		type = nd_finalize_pending_read_if_needed(type)
	int op = compound_assign_op()
	if (op):
		get_token()
		expression_is_assignment = 1
		return compound_assign_scalar(op, type, 0)
	if (accept(c"=")):
		if (expression_lhs_readonly):
			error(c"cannot assign to read-only buffer field")
		if ((type_is_value(type)) | (type == 3) | (type == 4)):
			error(c"assignment target is not assignable")
		if (type_is_const(type)):
			error(c"assignment to const")
		expression_is_assignment = 1
		expression_lhs_readonly = 0
		lint_check_condition_assign(eq_line, eq_column)
		char* self_name = lint_self_assign_begin(lhs_tokens, last_identifier)
		int rhs_serial = token_serial
		int lhs_slot = push_slot()
		# Recursion-depth guard (compiler/tokenizer.w): 'a = b = c = ...'
		# chains recurse this function directly for each right-hand side,
		# and each level's left operand has already returned by this point,
		# so unary_expression()'s entry guard never sees the chain grow.
		# Count each nested assignment here; same counter, limit and
		# message as the operand-level guard.
		expr_nesting_depth = expr_nesting_depth + 1
		if (expr_nesting_depth > 1000):
			error(c"expression nesting too deep")
		int type2 = expression()
		expr_nesting_depth = expr_nesting_depth - 1
		lint_self_assign_end(self_name, token_serial - rhs_serial, eq_line, eq_column)
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

		type = type_value(type_strip_gpu(type))  # assignment yields the stored value

	return type
