/*
 * conditional-expr (C-style ternary, docs/projects/golf_ergonomics.md):
 *         logical-or-expr
 *         logical-or-expr ? expression : conditional-expr
 *
 * The postfix '?' on wresult[T]* operands binds tighter and is claimed
 * by postfix_expr before this layer ever sees the token, so ternaries
 * and error propagation coexist. The else arm recurses into this layer,
 * making chained conditionals right-associative like C.
 *
 * The then arm decides the result type (an untyped constant arm defers
 * to the else arm); the else arm is coerced to it inside its own branch,
 * before the join point, so both paths deliver the same representation.
 *
 * This file is compiled by the committed seed: only seed-understood
 * syntax here.
 */

int expression();


# 1 for the promote() pseudo-types whose value already sits in eax with
# a representation of its own (floats, strings, vars, slices): those must
# not be re-encoded with type_value().
int conditional_arm_is_value(int t):
	if ((t == 3) | (t == 4)):
		return 1
	if ((t == float32_value_type) | (t == float64_value_type)):
		return 1
	if ((t == string_value_type) | (t == var_value_type)):
		return 1
	if (type_get_kind(t) == type_kind_slice_value()):
		return 1
	return 0


int conditional_expr():
	int type = logical_or_expr()
	if (peek(c"?") == 0):
		return type
	get_token() /* consume '?' */
	promote(type)
	jmp_zero_int32(1337)
	int p_else = codepos
	int then_type = expression()
	then_type = promote(then_type)
	expect(c":")
	jmp_int32(1337)
	int p_end = codepos
	be_branch_patch(p_else, codepos)
	int else_type = conditional_expr()
	else_type = promote(else_type)
	# An untyped constant then-arm takes the else arm's type ('c ? 1 : x')
	int result = then_type
	if (then_type == 3):
		result = else_type
	else:
		# Convert the else value to the then arm's representation while
		# still on the else path, ahead of the join point
		coerce(then_type, else_type)
	if (types_compatible(type_real(result), type_real(else_type)) == 0):
		warn_type_mismatch(c"conditional arms", then_type, else_type)
	be_branch_patch(p_end, codepos)
	if (conditional_arm_is_value(result)):
		return result
	if (type_is_value(result)):
		return result
	# Structs stay by-address (the promote convention); scalars become
	# rvalues so the ternary result is never an assignment target
	if (type_num_args(type_real(result)) > 0):
		return result
	return type_value(type_real(result))
