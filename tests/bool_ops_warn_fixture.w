# Widened bool-bitwise condition hint (opt-in `w check --bool-ops`,
# grammar/binary_op.w operand_is_bool_condition): bitwise '|' / '&'
# joining comparison-result bool operands inside an if or while
# condition gets the same short-circuit hint as two bool lvalues. A
# plain `w check` must stay silent on this file — comparison results
# are exempt by default (long-established W style). The
# check_bool_ops_test target runs this fixture both ways and freezes
# the message text; the flag-off silence is asserted with
# reject_stderr, so no expect_stderr directives here. No imports: the
# hint fires wherever code compiles, so an imported library's own
# (stage-2) sites would drown the fixture's.


int main():
	int x = 3
	int y = 4
	bool ready = x == y
	# Widened scope: both operands are comparison results
	if ((x == 1) | (y == 2)):
		return 1
	while ((x > 0) & (y > 0)):
		return 2
	# Mixed operands: a bool lvalue joined with a comparison result is
	# silent by default (only the lvalue side qualifies) but fires under
	# --bool-ops
	if (ready | (x == 3)):
		return 3
	return 0
