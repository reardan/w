# A decimal literal above 4294967295 does not fit the compiler's
# 32-bit decode and used to wrap silently; grammar/int_literal.w now
# rejects it. 4294967296 is one past the bound and exercises the
# ten-digit string comparison against the maximum — the legal
# 4294967295 boundary case lives in tests/int_literal_bounds_test.w.
# expect_stderr: integer literal overflows 32 bits: 4294967296
# expect_stderr: int_literal_overflow_decimal_fixture.w:13
# expect_fail
import lib.lib


int main():
	int x = 4294967296
	return x
