# A binary literal with more than 32 significant digits does not fit
# the compiler's 32-bit decode and used to wrap silently;
# grammar/int_literal.w now rejects it. This literal is 33 one-bits —
# one past the widest legal form, whose positive case lives in
# tests/int_literal_bounds_test.w.
# expect_stderr: integer literal overflows 32 bits: 0b111111111111111111111111111111111
# expect_stderr: int_literal_overflow_binary_fixture.w:13
# expect_fail
import lib.lib


int main():
	int x = 0b111111111111111111111111111111111
	return x
