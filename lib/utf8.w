import lib.lib
import lib.assert


int utf8_validate_bytes(char* data, int length):
	int i = 0
	int cp = 0
	while (i < length):
		int n = utf8_scan(data + i, length - i, &cp)
		if (n == 0):
			return 0
		i = i + n
	return 1


int utf8_validate(string s):
	return utf8_validate_bytes(s.data, s.length)


int utf8_next(string s, int byte_index):
	assert1(byte_index >= 0)
	assert1(byte_index < s.length)
	int c = s.data[byte_index] & 255
	if (c < 128):
		return byte_index + 1
	if (c < 224):
		return byte_index + 2
	if (c < 240):
		return byte_index + 3
	return byte_index + 4


# The codepoint at byte_index; U+FFFD when the bytes there are not a
# valid sequence (lib/lib.w utf8_scan).
int utf8_decode(string s, int byte_index):
	assert1(byte_index >= 0)
	assert1(byte_index < s.length)
	int cp = 0
	if (utf8_scan(s.data + byte_index, s.length - byte_index, &cp) == 0):
		return 65533
	return cp


int utf8_encode(char* out, int codepoint):
	assert1(codepoint >= 0)
	assert1((codepoint < 55296) | (codepoint > 57343))
	assert1(codepoint <= 1114111)
	if (codepoint < 128):
		out[0] = codepoint
		return 1
	if (codepoint < 2048):
		out[0] = 192 | (codepoint >> 6)
		out[1] = 128 | (codepoint & 63)
		return 2
	if (codepoint < 65536):
		out[0] = 224 | (codepoint >> 12)
		out[1] = 128 | ((codepoint >> 6) & 63)
		out[2] = 128 | (codepoint & 63)
		return 3
	out[0] = 240 | (codepoint >> 18)
	out[1] = 128 | ((codepoint >> 12) & 63)
	out[2] = 128 | ((codepoint >> 6) & 63)
	out[3] = 128 | (codepoint & 63)
	return 4


int utf8_is_boundary(string s, int byte_index):
	if ((byte_index < 0) || (byte_index > s.length)):
		return 0
	if ((byte_index == 0) || (byte_index == s.length)):
		return 1
	int c = s.data[byte_index] & 255
	return (c < 128) | (c > 191)


int utf8_codepoint_count(string s):
	int count = 0
	int i = 0
	while (i < s.length):
		i = utf8_next(s, i)
		count = count + 1
	return count


int utf8_equals(string a, string b):
	if (a.length != b.length):
		return 0
	int i = 0
	while (i < a.length):
		if (a.data[i] != b.data[i]):
			return 0
		i = i + 1
	return 1


int string_starts_with(string s, string prefix):
	if (prefix.length > s.length):
		return 0
	int i = 0
	while (i < prefix.length):
		if (s.data[i] != prefix.data[i]):
			return 0
		i = i + 1
	return 1


int string_ends_with(string s, string suffix):
	if (suffix.length > s.length):
		return 0
	int offset = s.length - suffix.length
	int i = 0
	while (i < suffix.length):
		if (s.data[offset + i] != suffix.data[i]):
			return 0
		i = i + 1
	return 1


string string_from_bytes(char* data, int length):
	assert1(utf8_validate_bytes(data, length))
	char* descriptor = malloc(2 * __word_size__ + length + 1)
	char* out = descriptor + 2 * __word_size__
	save_word(descriptor, cast(int, out))
	save_word(descriptor + __word_size__, length)
	for i in range(length):
		out[i] = data[i]
	out[length] = 0
	return cast(string, cast(int, descriptor))


# Borrowing string -> char* seam: returns s.data directly after asserting
# the bytes are NUL-terminated with no interior NULs (true for string
# literals and f-string/builder results, not for arbitrary slices). The
# pointer lives exactly as long as s's buffer and must not be freed
# independently. For an owned copy — or for any string this would reject —
# use cstr_clone.
char* cstr(string s):
	int i = 0
	while (i < s.length):
		assert1(s.data[i] != 0)
		i = i + 1
	assert1(s.data[s.length] == 0)
	return s.data


# Copying string -> char* seam: allocate s.length + 1 bytes, copy the
# UTF-8 bytes verbatim and append a NUL. Unlike cstr this accepts any
# string — slices and other views included — because it never reads past
# s.length. The result is malloc'd and owned by the caller (free() it
# when done, like strclone). Interior NUL bytes are copied through, not
# rejected: the buffer always holds all s.length bytes plus the
# terminator, but a char* consumer will see the content truncated at the
# first interior NUL.
char* cstr_clone(string s):
	char* out = malloc(s.length + 1)
	for i in range(s.length):
		out[i] = s.data[i]
	out[s.length] = 0
	return out


void utf8_write(int file, string s):
	cstr_utf8_length_or_die(s.data)
	write(file, s.data, s.length)


void utf8_print(string s):
	utf8_write(1, s)
