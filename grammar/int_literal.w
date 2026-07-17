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


# The literal accumulator is the compiler's own word-sized int, and the
# 32-bit self-host bootstraps every target, so a hex or binary literal
# keeps only the low 32 bits of its digits: before this check,
# 0x7ff0000000000000 silently parsed to 0 on the x64 target. Reject any
# literal whose significant digits cannot fit in 32 bits instead of
# wrapping. Leading zeros carry no bits, so 0x00000000ffffffff stays
# legal; digit counting mirrors the decoders exactly (from_hex skips
# non-hex characters, the binary loop shifts for every character). Wide
# constants must be assembled at runtime from 32-bit pieces (see
# lib/sha256.w's runtime-built masks).
void int_literal_width_check():
	int digits = 0
	int i = 2
	if (token[1] == 'x'):
		while (token[i]):
			int ch = token[i]
			int is_digit = 0
			if (('0' <= ch) & (ch <= '9')):
				is_digit = 1
			if (('a' <= ch) & (ch <= 'f')):
				is_digit = 1
			if (('A' <= ch) & (ch <= 'F')):
				is_digit = 1
			if (is_digit):
				if ((digits > 0) | (ch != '0')):
					digits = digits + 1
			i = i + 1
		if (digits > 8):
			error(c"integer literal has more than 32 significant bits; assemble wide constants at runtime from 32-bit pieces")
	else:
		while (token[i]):
			if ((digits > 0) | (token[i] != '0')):
				digits = digits + 1
			i = i + 1
		if (digits > 32):
			error(c"integer literal has more than 32 significant bits; assemble wide constants at runtime from 32-bit pieces")


# The decimal decoder shares the same 32-bit ceiling: after skipping
# leading zeros, more than 10 digits always overflows, and exactly 10
# digits overflow when the digit string compares greater than
# 4294967295, the largest 32-bit value. A negative literal is '-'
# applied to a positive literal, so the positive-form bound is the one
# that matters. No-op on a token that is not a decimal literal, so call
# sites that fall back to atoi() can guard unconditionally.
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
		error(c"integer literal has more than 32 significant bits; assemble wide constants at runtime from 32-bit pieces")
	else if (digits == 10):
		if (strcmp(token + i, c"4294967295") > 0):
			error(c"integer literal has more than 32 significant bits; assemble wide constants at runtime from 32-bit pieces")


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
		int_literal_width_check()
		n = from_hex(token + 2)
		int_literal_bit31_check(n)
		if (negative):
			n = 0-n
		mov_eax_int(n)
		return 1

	# Binary literal e.g. 0b1010, mirroring the hex path ('_' digit
	# separators are a possible follow-up)
	if ((token[0] == '0') & (token[1] == 'b')):
		int_literal_width_check()
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
