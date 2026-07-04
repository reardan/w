# Attempt to decode an int literal
int int_literal():
	int negative = 0
	int n = 0
	int i = 0

	# Check to see if theres a negative sign
	if (accept(c"-")):
		negative = 1

	# Hex literal e.g. 0x1f (lowercase digits)
	if ((token[0] == '0') & (token[1] == 'x')):
		n = from_hex(token + 2)
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
