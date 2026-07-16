# Negative cases for the widened bool-bitwise condition hint: even with
# `w check --bool-ops` (grammar/binary_op.w operand_is_bool_condition)
# these stay silent — short-circuit spellings, bool arithmetic outside
# an if/while condition, and integer bitwise operands are all fine. The
# check_bool_ops_test target asserts this file produces no warnings
# with the flag on. No imports: an imported library's own (stage-2)
# sites would fire here and break the silence assertion.


int main():
	int x = 3
	int y = 4
	# Outside a condition: accumulating comparison results with '|' is
	# not a guard and stays silent
	bool either = (x == 1) | (y == 2)
	# The short-circuit spellings are what the hint asks for
	if ((x == 1) || (y == 2)):
		return 1
	while ((x > 0) && (y > 0)):
		return 2
	# Integer bitwise stays integer bitwise, even inside a condition
	if ((x & 3) == (y | 1)):
		return 3
	return cast(int, either)
