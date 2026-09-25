int string_hex_digit(int c):
	if ((c >= '0') && (c <= '9')):
		return c - '0'
	if ((c >= 'a') && (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') && (c <= 'F')):
		return c - 'A' + 10
	error(c"invalid hex digit in string literal")
	return 0


int string_hex_value(int start, int count):
	int value = 0
	for i in range(count):
		value = (value << 4) + string_hex_digit(token[start + i])
	return value


int string_append_utf8(int out, int codepoint):
	if (codepoint < 0):
		error(c"invalid unicode codepoint")
	if ((codepoint >= 55296) && (codepoint <= 57343)):
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


# Decode the UTF-8 sequence at token[i] (n bytes of text): returns the
# codepoint and sets utf8_decoded_length, or a negative error -- -1 bad
# lead byte, -2 truncated, -3 bad continuation byte, -4 overlong. The
# surrogate and range checks stay with the callers, whose messages
# differ. Shared by char literals and string-literal validation.
int utf8_decoded_length


int string_utf8_decode(int i, int n):
	int c = token[i] & 255
	utf8_decoded_length = 1
	if (c < 128):
		return c
	int need = 0
	int codepoint = 0
	if ((c >= 194) && (c <= 223)):
		need = 1
		codepoint = c & 31
	else if ((c >= 224) && (c <= 239)):
		need = 2
		codepoint = c & 15
	else if ((c >= 240) && (c <= 244)):
		need = 3
		codepoint = c & 7
	else:
		return -1
	if (i + need >= n):
		return -2
	for j in range(1, need + 1):
		int d = token[i + j] & 255
		if ((d < 128) || (d > 191)):
			return -3
		codepoint = (codepoint << 6) | (d & 63)
	if (((need == 2) && (codepoint < 2048)) || ((need == 3) && (codepoint < 65536))):
		return -4
	utf8_decoded_length = need + 1
	return codepoint


# Map a simple backslash-escape character to its byte value: \n \t \r \0,
# plus the identity escapes for backslash and both quotes. Returns -1 for
# anything unrecognized; string literals keep the character literally
# (documented leniency), char literals reject it.
int escape_char_value(int c):
	if (c == 'n'):
		return 10
	if (c == 't'):
		return 9
	if (c == 'r'):
		return 13
	if (c == '0'):
		return 0
	if (c == 92):
		return 92
	if (c == 39):
		return 39
	if (c == '"'):
		return '"'
	return -1


# Decode the current token as a char literal and return its value: a plain
# ASCII byte ('a'), a backslash escape ('\n', '\x41', '\u00e9',
# '\U0001F600'), or a raw UTF-8 sequence ('é') whose value is the Unicode
# codepoint. The caller has checked token[0] is a single quote. Unknown
# escapes and multi-character literals are compile errors, unlike string
# literals which keep unknown escapes literally.
int char_literal_value():
	if ((token[1] == 39) && (token[2] == 0)):
		error(c"empty char literal")
	int value
	int end
	if (token[1] == 92):
		int e = token[2] & 255
		if (e == 'x'):
			value = string_hex_value(3, 2)
			end = 5
		else if (e == 'u'):
			value = string_hex_value(3, 4)
			end = 7
		else if (e == 'U'):
			value = string_hex_value(3, 8)
			end = 11
		else:
			value = escape_char_value(e)
			if (value < 0):
				error2(c"unknown escape in char literal: ", token)
			end = 3
	else:
		value = string_utf8_decode(1, strlen(token))
		if (value < 0):
			error2(c"invalid UTF-8 char literal: ", token)
		end = 1 + utf8_decoded_length
	if ((value >= 55296) && (value <= 57343)):
		error(c"invalid unicode surrogate")
	if (value > 1114111):
		error(c"unicode codepoint out of range")
	if ((token[end] != 39) || (token[end + 1] != 0)):
		error2(c"multi-character char literal: ", token)
	return value


int process_string_literal_from(int j):
	int i = 0
	int k
	while (token[j] != '"'):
		# \x0a formatting
		if ((token[j] == 92) && (token[j + 1] == 'x')):
			k = string_hex_value(j + 2, 2)
			token[i] = k
			j = j + 4

		else if ((token[j] == 92) && (token[j + 1] == 'u')):
			k = string_hex_value(j + 2, 4)
			i = string_append_utf8(i, k) - 1
			j = j + 6

		else if ((token[j] == 92) && (token[j + 1] == 'U')):
			k = string_hex_value(j + 2, 8)
			i = string_append_utf8(i, k) - 1
			j = j + 10

		# standard escapes: \n \t \r \0 (anything else is taken literally)
		else if (token[j] == 92):
			k = escape_char_value(token[j + 1])
			if (k < 0):
				k = token[j + 1]
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
		int codepoint = string_utf8_decode(i, n)
		if (codepoint == -1):
			error(c"invalid UTF-8 string literal")
		if (codepoint == -2):
			error(c"truncated UTF-8 string literal")
		if (codepoint == -3):
			error(c"invalid UTF-8 continuation byte")
		if (codepoint == -4):
			error(c"overlong UTF-8 string literal")
		if ((codepoint >= 55296) && (codepoint <= 57343)):
			error(c"invalid UTF-8 surrogate")
		if (codepoint > 1114111):
			error(c"UTF-8 codepoint out of range")
		i = i + utf8_decoded_length


# like a char_pointer_literal()
# except it emits the code directly to be executed
int raw_asm_literal():
	if (accept(c"raw_asm") == 0):
		return 0
	if (target_isa == 3):
		error(c"raw_asm is not supported in gpu code")
	expect(c"(")
	if ((token[0] != '"') && (((token[0] != 'c') || (token[1] != '"')))):
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


# A64: the string bytes stay inline in text (branched over, padded so the
# branch target stays 4-byte aligned), but the {data_ptr,len} descriptor
# lives in the RW data segment: its data_ptr cell holds an absolute vaddr
# that the entry stub must slide under PIE, and the text segment is
# read-execute so it could not be patched there. The cell is recorded in
# the rebase table and the descriptor's address is materialized with a
# PC-relative adrp+add.
void arm64_emit_utf8_string_descriptor(int i):
	int pad = (4 - ((i + 1) & 3)) & 3
	int data_bytes = (i + 1) + pad
	a64(op(0x14, 0x000000) | (((4 + data_bytes) >> 2) & op(0x03, 0xffffff))) /* b over the bytes */
	int data_address = code_offset + codepos
	emit(i + 1, token)
	emit_zeros(pad)
	int desc_vaddr = emit_data_zeros(2 * word_size)
	save_i(data + (desc_vaddr - data_offset), data_address, word_size)
	save_i(data + (desc_vaddr - data_offset + word_size), i, word_size)
	rebase_note(desc_vaddr)
	be_addr_slot_emit()
	be_addr_slot_write(codepos - 4, desc_vaddr)


# wasm: code is not addressable memory, so both the string bytes and the
# {data_ptr, len} descriptor live in the data segment; the descriptor's
# address is materialized through an ordinary address slot.
void wasm_emit_utf8_string_descriptor(int i):
	int data_address = emit_data_zeros(i + 1)
	for j in range(i + 1):
		data[(data_address - data_offset) + j] = token[j]
	int desc_vaddr = emit_data_zeros(2 * word_size)
	save_i(data + (desc_vaddr - data_offset), data_address, word_size)
	save_i(data + (desc_vaddr - data_offset + word_size), i, word_size)
	be_addr_slot_emit()
	be_addr_slot_write(codepos - 4, desc_vaddr)


void emit_utf8_string_descriptor(int i):
	token[i] = 0
	if (target_isa == 3):
		error(c"strings are not supported in gpu code")
		return
	if (target_isa == 2):
		wasm_emit_utf8_string_descriptor(i)
		return
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
void arm64_emit_cstr(int i, char* s):
	int pad = (4 - ((i + 1) & 3)) & 3
	int data_bytes = (i + 1) + pad
	a64(op(0x94, 0x000000) | (((4 + data_bytes) >> 2) & op(0x03, 0xffffff))) /* bl over the string */
	emit(i + 1, s)
	emit_zeros(pad)
	a64(op(0xaa, 0x1e03e0)) /* mov x0, x30 (string address) */


# Emit s[0..len] (a NUL-terminated blob) inline in the code stream and
# leave its address in the accumulator. Used by c"..." literals, the
# f"..." template-string chunk appender, and the synthesized test
# registry. x86 jumps over the bytes with a call and pops the pushed
# return address; arm64 uses arm64_emit_cstr.
void be_emit_inline_cstr(int len, char* s):
	if (target_isa == 3):
		error(c"strings are not supported in gpu code")
		return
	if (target_isa == 2):
		# data segment + plain constant address (no chain: the address is
		# already final)
		int addr = emit_data_zeros(len + 1)
		for j in range(len + 1):
			data[(addr - data_offset) + j] = s[j]
		wasm_mov_eax_int(addr)
		return
	if (target_isa == 1):
		arm64_emit_cstr(len, s)
		return
	call_relative32(len + 1)
	emit(len + 1, s)
	pop_eax()


int c_char_pointer_literal():
	if ((token[0] != 'c') || (token[1] != '"')):
		return 0
	int i = process_prefixed_string_literal()
	token[i] = 0
	be_emit_inline_cstr(i, token)
	return 1


int utf8_string_literal():
	if ((token[0] != 's') || (token[1] != '"')):
		return 0
	int i = process_prefixed_string_literal()
	validate_utf8_literal(i)
	emit_utf8_string_descriptor(i)
	return 1
