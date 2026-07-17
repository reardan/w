# The binary literal decoder shifts once per digit into the same
# 32-bit accumulator as the hex path, so a literal with more than 32
# significant digits used to drop its high bits silently. It is now a
# compile error (grammar/int_literal.w); a full 32-digit mask stays
# legal (see tests/warning_clean_fixture.w).
# expect_fail
# expect_stderr: integer literal has more than 32 significant bits; assemble wide constants at runtime from 32-bit pieces
# expect_stderr: int_literal_width_binary_error_fixture.w:10
int main():
	return 0b100000000000000000000000000000000
