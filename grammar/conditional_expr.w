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
 * One exception mirrors that coercion the other way: an array/slice
 * value in the then arm decays to an else arm's pointer type (or, when
 * the else arm is a bare constant, to its own element pointer) through
 * a stub spliced in after the else arm, since the then arm's code is
 * already emitted when the else arm's type becomes known. An array/
 * slice value in the else arm likewise decays against a constant then
 * arm, so the join never carries a slice-value type whose constant path
 * would be read through by an outer decay load.
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
	# Three regions: h_join ends at the join point, h_stub ends where the
	# then arm's code resumes (usually also the join, but a decay stub can
	# be spliced in below once the else arm's type is known), h_else ends
	# where the else arm starts.
	int h_join = be_ctrl_block()
	int h_stub = be_ctrl_block()
	int h_else = be_ctrl_block()
	be_br_zero(h_else)
	int then_type = expression()
	then_type = promote(then_type)
	expect(c":")
	be_br(h_stub)
	be_ctrl_end(h_else)
	int else_type = conditional_expr()
	else_type = promote(else_type)
	# An untyped constant then-arm takes the else arm's type ('c ? 1 : x')
	int result = then_type
	int then_is_slice_value = type_get_kind(type_unqualified(then_type)) == type_kind_slice_value()
	int else_is_slice_value = type_get_kind(type_unqualified(else_type)) == type_kind_slice_value()
	if (then_type == 3):
		result = else_type
		if (else_is_slice_value):
			# 'c ? 0 : arr': the constant arm is already a bare word (a
			# null pointer, usually), so decay the array/slice arm to its
			# element pointer in-branch. A joined slice-value type would
			# make an outer decay load read through the constant.
			promote_eax()
			result = type_get_next_pointer(type_unqualified(type_get_element_type(type_unqualified(else_type))))
		# The then arm resumes directly at the join (an empty stub region)
		be_ctrl_end(h_stub)
	else if (type_decays_to_pointer(else_type, then_type) | (then_is_slice_value & (else_type == 3))):
		# 'c ? arr : ptr' joins at the else arm's pointer type,
		# 'c ? arr : 0' at the element pointer. The then arm's code is
		# already emitted, so end its region at a stub that loads the
		# descriptor's first word (the data pointer); the else path
		# jumps over the stub to the join point.
		result = else_type
		if (else_type == 3):
			result = type_get_next_pointer(type_unqualified(type_get_element_type(type_unqualified(then_type))))
		be_br(h_join)
		be_ctrl_end(h_stub)
		promote_eax()
	else:
		# Convert the else value to the then arm's representation while
		# still on the else path, ahead of the join point; the then arm
		# resumes directly at the join (an empty stub region)
		coerce(then_type, else_type)
		be_ctrl_end(h_stub)
	int arms_compatible = types_compatible(type_real(result), type_real(else_type))
	if (arms_compatible == 0):
		# 'c ? ptr : arr': coerce just decayed the else arm in-branch
		arms_compatible = type_decays_to_pointer(type_real(result), type_real(else_type))
	if (arms_compatible == 0):
		warn_type_mismatch(c"conditional arms", then_type, else_type)
	be_ctrl_end(h_join)
	if (conditional_arm_is_value(result)):
		return result
	if (type_is_value(result)):
		return result
	# Structs stay by-address (the promote convention); scalars become
	# rvalues so the ternary result is never an assignment target
	if (type_num_args(type_real(result)) > 0):
		return result
	return type_value(type_real(result))
