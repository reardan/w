# A hex or binary literal with bit 31 set sign-extends into the
# word-sized 'int' on every target (0xffffffff is -1 even on x64), so
# mask-building code silently goes negative. Warn unless the literal
# sits inside a cast(T, ...) operand — cast() is the documented escape
# hatch for conversions the checks would otherwise flag, so
# cast(int, 0xffffffff) spells "this bit pattern is intentional".
# '(n >> 31) & 1' reads bit 31 identically whether this compiler binary
# has 4- or 8-byte ints, so self-hosts on every target warn alike.
void int_literal_bit31_check(int n):
	if (cast_context):
		return
	if ((n >> 31) & 1):
		warning(c"warning: integer literal has bit 31 set and sign-extends to a negative int on every target; use cast(int, ...) if the bit pattern is intended")


# The compiler always runs as a 32-bit process, so a literal with more
# than 32 bits of significance cannot survive the word-sized decode:
# 0x7ff0000000000000 used to silently wrap to 0 on the x64 target.
# Reject such literals instead. Significance ignores leading zeros —
# 0x00000000ffffffff still fits in 32 bits and stays legal — and the
# rule is the same for every literal form. Wide constants are assembled
# at runtime from sub-32-bit pieces instead: (hi << 32) | lo, the
# lib/sha256.w mask idiom.
void int_literal_overflow_error():
	diag_part(c"integer literal overflows 32 bits: ")
	error(token)


# Hex and binary literals share a digit-count rule: skip the
# two-character prefix ("0x"/"0b") and any leading zeros, then allow at
# most max_digits significant digits (8 hex digits or 32 binary digits
# = 32 bits).
void int_literal_width_check(int max_digits):
	int i = 2
	while (token[i] == '0'):
		i = i + 1
	int digits = 0
	while (token[i + digits]):
		digits = digits + 1
	if (digits > max_digits):
		int_literal_overflow_error()


# Decimal literals: after skipping leading zeros, more than 10 digits
# always overflows and exactly 10 digits overflow when the digit string
# compares greater than 4294967295, the largest 32-bit value. A
# negative literal is '-' applied to a positive literal, so the
# positive-form bound is the one that matters. No-op on a token that is
# not a decimal literal, so call sites that fall back to atoi() can
# guard unconditionally.
void int_literal_decimal_check():
	if ((token[0] < '0') | (token[0] > '9')):
		return
	int i = 0
	while (token[i] == '0'):
		i = i + 1
	int digits = 0
	while (token[i + digits]):
		digits = digits + 1
	if (digits > 10):
		int_literal_overflow_error()
	else if (digits == 10):
		if (strcmp(token + i, c"4294967295") > 0):
			int_literal_overflow_error()


# Attempt to decode an int literal
int int_literal():
	int negative = 0
	int n = 0
	int i = 0

	# Check to see if theres a negative sign
	if (accept(c"-")):
		negative = 1

	# Hex literal e.g. 0x1f or 0x1F
	if ((token[0] == '0') & (token[1] == 'x')):
		int_literal_width_check(8)
		n = from_hex(token + 2)
		int_literal_bit31_check(n)
		if (negative):
			n = 0-n
		mov_eax_int(n)
		return 1

	# Binary literal e.g. 0b1010, mirroring the hex path ('_' digit
	# separators are a possible follow-up)
	if ((token[0] == '0') & (token[1] == 'b')):
		int_literal_width_check(32)
		i = 2
		while (token[i]):
			n = (n << 1) + token[i] - '0'
			i = i + 1
		int_literal_bit31_check(n)
		if (negative):
			n = 0-n
		mov_eax_int(n)
		return 1

	# Check for digits 0-9
	if ((token[i]) < '0' | (token[i] > '9')):
		return 0

	int_literal_decimal_check()

	# Decode remaining digits
	while (token[i]):
		n = (n << 1) + (n << 3) + token[i] - '0'
		i = i + 1

	# Handle negative
	if (negative):
		n = 0-n
	# Put int literal into eax
	mov_eax_int(n)
	return 1
