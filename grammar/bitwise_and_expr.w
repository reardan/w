/*
 * bitwise-and-expr:
 *         equality-expr
 *         bitwise-and-expr & equality-expr
 */
int bitwise_and_expr():
	int call_count_before = emitted_call_count
	int type = equality_expr()
	# Chain-tracked across a same-precedence run of '&': a fold's result
	# is itself bool/pure exactly when both the sides it just joined were
	# (a bitwise AND of two 0/1 values is a genuine 0/1 result), so a 3+
	# term chain keeps qualifying past the first pairing instead of
	# losing bool-ness to binary2_finish_pop's untyped placeholder return.
	int chain_is_bool = operand_is_bool_condition(type)
	int chain_is_pure = operand_is_pure(call_count_before)
	while (peek(c"&")):
		# Captured before accept() consumes '&' and advances the
		# lookahead, so the warning (if any) points at the operator
		# itself rather than wherever parsing the right operand leaves
		# the tokenizer.
		int op_line_number = line_number
		int op_diag_token_line = diag_token_line
		int op_diag_token_column = diag_token_column
		accept(c"&")
		# Checked before binary1() promotes the left operand to a value
		int left_is_bool = chain_is_bool
		int left_is_pure = chain_is_pure
		int left_type = binary1(type)
		int right_call_count_before = emitted_call_count
		int right_type = equality_expr()
		int right_is_bool = operand_is_bool_condition(right_type)
		int right_is_pure = operand_is_pure(right_call_count_before)
		if (var_binary_operands(left_type, right_type)):
			error(c"var operands do not support &")
		if (condition_context && left_is_bool && right_is_bool):
			# Default: both operands call-free, so '&&' is semantics-
			# preserving. --bool-ops also reports the call-containing
			# joins this excludes.
			if ((left_is_pure && right_is_pure) || check_bool_ops_mode):
				warn_bool_bitwise_at(c"warning: bitwise '&' on bool operands in a condition does not short-circuit; did you mean '&&'?", op_line_number, op_diag_token_line, op_diag_token_column, c"&")
		type = binary2_finish_pop(right_type)
		chain_is_bool = left_is_bool && right_is_bool
		chain_is_pure = left_is_pure && right_is_pure
		alu_and()

	return type
