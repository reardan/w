/*
 * equality-expr:
 *         relational-expr
 *         equality-expr == relational-expr
 *         equality-expr != relational-expr
 */

# fn_name(ebx, eax) for an always-imported runtime helper (the
# auto-imported container runtime); the result stays in eax.
void emit_runtime_call_ebx_eax(char* fn_name):
	int base_stack = stack_pos
	int right_slot = push_slot()
	mov_eax_ebx()
	int left_slot = push_slot()
	int s = rt_call_begin(fn_name)
	push_slot_copy(left_slot)
	push_slot_copy(right_slot)
	rt_call_end(s)
	pop_to(base_stack)


# == / != on two string operands (variables, literals, f-strings)
# compare contents: __w_string_equal (structures/hash_table.w, always
# imported) is null-safe, a null descriptor equals only null. A string
# against anything else (the constant 0 of a null check, a char*) keeps
# the word comparison. Left operand in ebx, right in eax. Returns the
# bool value type, or 0 when the operands are not both strings.
int string_binary_compare_eq(int left_type, int right_type, int negate):
	if ((type_is_string(type_unqualified(left_type)) && type_is_string(type_unqualified(right_type))) == 0):
		return 0
	emit_runtime_call_ebx_eax(c"__w_string_equal")
	if (negate):
		alu_test_set(0x94) /* sete: invert the 0/1 result */
	return type_value(bool_type)


# Shared lowering for == and !=: cc is the sete/setne byte used by the
# float and integer layers; negate tells the var layer to invert the
# __w_var_eq result for !=.
int equality_op(int type, int negate, int cc, int op_line_number, int op_diag_line, int op_diag_column):
	int left_type = binary1(type)
	int right_type = binary2_promote_pop(relational_expr())
	int result_type = var_binary_compare_eq(left_type, right_type, negate)
	if (result_type == 0): result_type = string_binary_compare_eq(left_type, right_type, negate)
	if (result_type == 0): result_type = float_binary_compare(left_type, right_type, cc, 0)
	if (result_type):
		return result_type
	# Struct values are used by address, so the word comparison below
	# compares where the two structs live, not their fields (#532)
	if (operand_is_struct_value(left_type) || operand_is_struct_value(right_type)):
		char* op_text = c"=="
		if (negate): op_text = c"!="
		warn_bool_bitwise_at(c"warning: '==' and '!=' on struct values compare their addresses, not their fields; compare the fields, or take '&' of both sides to compare addresses", op_line_number, op_diag_line, op_diag_column, op_text)
	alu_cmp_set(cc)
	return type_value(bool_type)


int equality_expr():
	int type = relational_expr()
	while (1):
		int op_line_number = line_number
		int op_diag_line = diag_token_line
		int op_diag_column = diag_token_column
		if (accept(c"==")):
			type = equality_op(type, 0, 0x94, op_line_number, op_diag_line, op_diag_column) /* sete */

		else if (accept(c"!=")):
			type = equality_op(type, 1, 0x95, op_line_number, op_diag_line, op_diag_column) /* setne */

		else:
			return type
