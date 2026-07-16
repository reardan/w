# A hex literal with more than 8 significant digits does not fit the
# compiler's 32-bit decode and used to wrap silently (the x64 target
# saw 0x7ff0000000000000 as 0); grammar/int_literal.w now rejects it.
# Leading zeros carry no significance — the legal 0x00000000ffffffff
# boundary case lives in tests/int_literal_bounds_test.w.
# expect_stderr: integer literal overflows 32 bits: 0x7ff0000000000000
# expect_stderr: int_literal_overflow_hex_fixture.w:13
# expect_fail
import lib.lib


int main():
	int x = 0x7ff0000000000000
	return x
