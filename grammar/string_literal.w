int string_hex_digit(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') & (c <= 'F')):
		return c - 'A' + 10
	error(c"invalid hex digit in string literal")
	return 0


int string_hex_value(int start, int count):
	int value = 0
	int i = 0
	while (i < count):
		value = (value << 4) + string_hex_digit(token[start + i])
		i = i + 1
	return value


int string_append_utf8(int out, int codepoint):
	if (codepoint < 0):
		error(c"invalid unicode codepoint")
	if ((codepoint >= 55296) & (codepoint <= 57343)):
		error(c"invalid unicode surrogate")
	if (codepoint > 1114111):
		error(c"unicode codepoint out of range")
	if (codepoint < 128):
		token[out] = codepoint
		return out + 1
	if (codepoint < 2048):
		token[out] = 192 | (codepoint >> 6)
		token[out + 1] = 128 | (codepoint & 63)
		return out + 2
	if (codepoint < 65536):
		token[out] = 224 | (codepoint >> 12)
		token[out + 1] = 128 | ((codepoint >> 6) & 63)
		token[out + 2] = 128 | (codepoint & 63)
		return out + 3
	token[out] = 240 | (codepoint >> 18)
	token[out + 1] = 128 | ((codepoint >> 12) & 63)
	token[out + 2] = 128 | ((codepoint >> 6) & 63)
	token[out + 3] = 128 | (codepoint & 63)
	return out + 4


int process_string_literal_from(int j):
	int i = 0
	int k
	while (token[j] != '"'):
		# \x0a formatting
		if ((token[j] == 92) & (token[j + 1] == 'x')):
			k = string_hex_value(j + 2, 2)
			token[i] = k
			j = j + 4

		else if ((token[j] == 92) & (token[j + 1] == 'u')):
			k = string_hex_value(j + 2, 4)
			i = string_append_utf8(i, k) - 1
			j = j + 6

		else if ((token[j] == 92) & (token[j + 1] == 'U')):
			k = string_hex_value(j + 2, 8)
			i = string_append_utf8(i, k) - 1
			j = j + 10

		# standard escapes: \n \t \r \0 (anything else is taken literally)
		else if (token[j] == 92):
			k = token[j + 1]
			if (k == 'n'):
				k = 10
			else if (k == 't'):
				k = 9
			else if (k == 'r'):
				k = 13
			else if (k == '0'):
				k = 0
			token[i] = k
			j = j + 2

		else:
			token[i] = token[j]
			j = j + 1

		i = i + 1
	return i


int process_string_literal():
	return process_string_literal_from(1)


int process_prefixed_string_literal():
	return process_string_literal_from(2)


void validate_utf8_literal(int n):
	int i = 0
	while (i < n):
		int c = token[i] & 255
		int need = 0
		int codepoint = 0
		if (c < 128):
			i = i + 1
		else if ((c >= 194) & (c <= 223)):
			need = 1
			codepoint = c & 31
		else if ((c >= 224) & (c <= 239)):
			need = 2
			codepoint = c & 15
		else if ((c >= 240) & (c <= 244)):
			need = 3
			codepoint = c & 7
		else:
			error(c"invalid UTF-8 string literal")
		if (need > 0):
			if (i + need >= n):
				error(c"truncated UTF-8 string literal")
			int j = 1
			while (j <= need):
				int d = token[i + j] & 255
				if ((d < 128) | (d > 191)):
					error(c"invalid UTF-8 continuation byte")
				codepoint = (codepoint << 6) | (d & 63)
				j = j + 1
			if ((need == 1) & (codepoint < 128)):
				error(c"overlong UTF-8 string literal")
			if ((need == 2) & (codepoint < 2048)):
				error(c"overlong UTF-8 string literal")
			if ((need == 3) & (codepoint < 65536)):
				error(c"overlong UTF-8 string literal")
			if ((codepoint >= 55296) & (codepoint <= 57343)):
				error(c"invalid UTF-8 surrogate")
			if (codepoint > 1114111):
				error(c"UTF-8 codepoint out of range")
			i = i + need + 1


# like a char_pointer_literal()
# except it emits the code directly to be executed
int raw_asm_literal():
	if (accept(c"raw_asm") == 0):
		return 0
	expect(c"(")
	if ((token[0] != '"') & (((token[0] != 'c') | (token[1] != '"')))):
		error(c"double quote expected inside raw_asm( ... ) literal")

	int i
	if (token[0] == 'c'):
		i = process_prefixed_string_literal()
	else:
		i = process_string_literal()
	emit(i, token)
	get_token()
	expect(c")")
	return 1


# A64: emit {data_ptr,len} descriptor + string bytes inline, branch over
# them with bl (which leaves the descriptor address in x30), and move it to
# the accumulator. String bytes are padded so the branch target stays
# 4-byte aligned.
void arm64_emit_utf8_string_descriptor(int i):
	int descriptor_size = 2 * word_size
	int pad = (4 - ((i + 1) & 3)) & 3
	int data_bytes = descriptor_size + (i + 1) + pad
	a64(op(0x94, 0x000000) | (((4 + data_bytes) >> 2) & op(0x03, 0xffffff))) /* bl over the data */
	int descriptor_addr = code_offset + codepos
	int data_address = descriptor_addr + descriptor_size
	emit_int64(data_address)
	emit_int64(i)
	emit(i + 1, token)
	emit_zeros(pad)
	a64(op(0xaa, 0x1e03e0)) /* mov x0, x30 (descriptor address) */


void emit_utf8_string_descriptor(int i):
	token[i] = 0
	if (target_isa == 1):
		arm64_emit_utf8_string_descriptor(i)
		return
	int descriptor_size = 2 * word_size
	call_relative32(descriptor_size + i + 1)
	int data_address = code_offset + codepos + descriptor_size
	if (word_size == 8):
		emit_int64(data_address)
		emit_int64(i)
	else:
		emit_int32(data_address)
		emit_int32(i)
	emit(i + 1, token)
	pop_eax()


int char_pointer_literal():
	if (token[0] != '"'):
		return 0
	int i = process_string_literal()
	validate_utf8_literal(i)
	emit_utf8_string_descriptor(i)

	return 1


# A64: emit the C string inline (padded to 4-byte alignment), branch over it
# with bl, and take the address bl left in x30.
void arm64_emit_cstr(int i):
	int pad = (4 - ((i + 1) & 3)) & 3
	int data_bytes = (i + 1) + pad
	a64(op(0x94, 0x000000) | (((4 + data_bytes) >> 2) & op(0x03, 0xffffff))) /* bl over the string */
	emit(i + 1, token)
	emit_zeros(pad)
	a64(op(0xaa, 0x1e03e0)) /* mov x0, x30 (string address) */


int c_char_pointer_literal():
	if ((token[0] != 'c') | (token[1] != '"')):
		return 0
	int i = process_prefixed_string_literal()
	token[i] = 0
	if (target_isa == 1):
		arm64_emit_cstr(i)
		return 1
	call_relative32(i + 1)
	emit(i + 1, token)
	pop_eax()
	return 1


int utf8_string_literal():
	if ((token[0] != 's') | (token[1] != '"')):
		return 0
	int i = process_prefixed_string_literal()
	validate_utf8_literal(i)
	emit_utf8_string_descriptor(i)
	return 1
