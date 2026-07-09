/*
 * equality-expr:
 *         relational-expr
 *         equality-expr == relational-expr
 *         equality-expr != relational-expr
 */

# Shared lowering for == and !=: cc is the sete/setne byte used by the
# float and integer layers; negate tells the var layer to invert the
# __w_var_eq result for !=.
int equality_op(int type, int negate, int cc):
	int left_type = binary1(type)
	int right_type = binary2_promote_pop(relational_expr())
	int result_type = var_binary_compare_eq(left_type, right_type, negate)
	if (result_type == 0):
		result_type = float_binary_compare(left_type, right_type, cc, 0)
	if (result_type):
		return result_type
	alu_cmp_set(cc)
	return type_value(bool_type)


int equality_expr():
	int type = relational_expr()
	while (1):
		if (accept(c"==")):
			type = equality_op(type, 0, 0x94) /* sete */

		else if (accept(c"!=")):
			type = equality_op(type, 1, 0x95) /* setne */

		else:
			return type
