# A hex or binary literal with bit 31 set sign-extends into the
# word-sized 'int' on every target (0xffffffff is -1 even on x64), so
# the compiler warns at the literal (grammar/int_literal.w); the
# warning_test target runs this fixture via bin/wfixture. Both literal
# forms fire — the file:line needles below pin one warning to the hex
# literal and one to the binary literal. cast(int, ...) suppresses the
# warning; that negative case lives in tests/warning_clean_fixture.w.
# expect_stderr: warning: integer literal has bit 31 set and sign-extends to a negative int on every target; use cast(int, ...) if the bit pattern is intended
# expect_stderr: bit31_literal_warning_fixture.w:15
# expect_stderr: bit31_literal_warning_fixture.w:16
import lib.lib


int main():
	int mask = 0xffffffff
	int high_bit = 0b10000000000000000000000000000000
	if (mask == high_bit):
		return 1
	return 0
