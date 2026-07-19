# Widened bool-bitwise condition hint, call-containing superset (opt-in
# `w check --bool-ops`, grammar/binary_op.w operand_is_pure): bitwise
# '|' / '&' joining two bool/comparison operands inside an if or while
# condition warns by DEFAULT when both operands are call-free (see
# tests/bool_bitwise_warning_fixture.w) — but when converting to
# '&&'/'||' would skip a function call the current '&'/'|' code always
# executes, that is not a safe rewrite, so the hint stays silent unless
# --bool-ops asks for it anyway. A plain `w check` must stay silent on
# this file; check_bool_ops_test runs it both ways and freezes the
# message text (the flag-off silence is asserted with reject_stderr, so
# no expect_stderr directives here). No imports: the hint fires
# wherever code compiles, so an imported library's own sites would
# drown the fixture's.


bool has_permission(int level):
	return level > 0


int call_count(int used):
	return used + 1


int main():
	int level = 1
	int used = 10
	# Call-containing operand: silent by default (skipping the call via
	# '&&'/'||' could change behavior), fires under --bool-ops
	if (has_permission(level) | (used == 10)):
		return 1
	while ((level == 1) & has_permission(level)):
		return 2
	# Both operands call-containing
	if (has_permission(level) | (call_count(used) > 0)):
		return 3
	return 0
