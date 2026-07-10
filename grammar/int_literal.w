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
		n = from_hex(token + 2)
		int_literal_bit31_check(n)
		if (negative):
			n = 0-n
		mov_eax_int(n)
		return 1

	# Binary literal e.g. 0b1010, mirroring the hex path ('_' digit
	# separators are a possible follow-up)
	if ((token[0] == '0') & (token[1] == 'b')):
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
