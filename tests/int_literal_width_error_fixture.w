# The int literal accumulator keeps only 32 bits, so a hex literal
# with more than 8 significant digits used to wrap silently
# (0x7ff0000000000000 parsed to 0 on the x64 target). It is now a
# compile error on every target (grammar/int_literal.w); leading zeros
# stay legal (see tests/warning_clean_fixture.w).
# expect_fail
# expect_stderr: integer literal has more than 32 significant bits; assemble wide constants at runtime from 32-bit pieces
# expect_stderr: int_literal_width_error_fixture.w:10
int main():
	return 0x7ff0000000000000
