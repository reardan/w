/*
Growable string builder.

The data buffer is always null-terminated, so it can be passed to any
function expecting a C string at any time.
*/
import lib.lib
import lib.assert


struct string_builder:
	int capacity
	int length
	char* data


string_builder* string_new_sized(int capacity):
	if (capacity < 8): capacity = 8
	# new sizes the struct per architecture; malloc(12) undersized it on x64.
	string_builder* s = new string_builder()
	s.capacity = capacity
	s.length = 0
	s.data = malloc(capacity)
	s.data[0] = 0
	return s


string_builder* string_new():
	return string_new_sized(16)


# Make sure extra more bytes (plus the terminator) fit.
void string_reserve(string_builder* s, int extra):
	int needed = s.length + extra + 1
	if (needed > s.capacity):
		int new_capacity = s.capacity * 2
		if (new_capacity < needed): new_capacity = needed
		# oldlen must be the allocation size (capacity), not the used
		# length: freelist_realloc only copies oldlen bytes so a short
		# oldlen "works" by accident, but the debug allocator checks
		# oldlen against the tracked malloc size and rejects a mismatch.
		s.data = realloc(s.data, s.capacity, new_capacity)
		s.capacity = new_capacity


void string_append(string_builder* s, char* c):
	int n = strlen(c)
	string_reserve(s, n)
	strcpy(s.data + s.length, c)
	s.length = s.length + n
	s.data[s.length] = 0


void string_append_char(string_builder* s, int c):
	string_reserve(s, 1)
	s.data[s.length] = c
	s.length = s.length + 1
	s.data[s.length] = 0


string_builder* string_from(char* c):
	string_builder* s = string_new_sized(strlen(c) + 1)
	string_append(s, c)
	return s


void string_append_int(string_builder* s, int v):
	char* digits = itoa(v)
	string_append(s, digits)
	free(digits)


int string_equals(string_builder* s, char* c):
	return strcmp(s.data, c) == 0


# Append exactly length bytes from data. Unlike string_append this copies
# through embedded NUL bytes, so it can carry string descriptor contents.
void string_append_bytes(string_builder* s, char* data, int length):
	string_reserve(s, length)
	for i in range(length): s.data[s.length + i] = data[i]
	s.length = s.length + length
	s.data[s.length] = 0


# Append a string descriptor's bytes (data pointer + length pair).
void string_append_string(string_builder* s, string v):
	string_append_bytes(s, v.data, v.length)


# A {data, length} string descriptor viewing the builder's buffer. The
# string shares storage with the builder: mutating or freeing the builder
# invalidates it. See str_from_cstr in lib/lib.w for the layout.
string string_builder_to_string(string_builder* s):
	char* descriptor = malloc(2 * __word_size__)
	save_word(descriptor, cast(int, s.data))
	save_word(descriptor + __word_size__, s.length)
	return cast(string, cast(int, descriptor))


/*
Runtime entry points for the compiler's f"..." template string lowering
(grammar/template_string.w). The __w_ prefix keeps them out of the user
namespace; the compiler resolves them by name, either directly when the
program imports structures.string itself or through backpatch chains
filled in by the deferred import at the end of compilation.
*/


string_builder* __w_template_new():
	return string_new()


void __w_template_bytes(string_builder* s, char* data, int length):
	string_append_bytes(s, data, length)


void __w_template_cstr(string_builder* s, char* text):
	string_append(s, text)


void __w_template_int(string_builder* s, int v):
	string_append_int(s, v)


void __w_template_str(string_builder* s, string v):
	string_append_string(s, v)


# Finish an f-string: hand the accumulated bytes to a string descriptor
# and free the builder struct (the data buffer now belongs to the string).
string __w_template_finish(string_builder* s):
	string result = string_builder_to_string(s)
	free(s)
	return result


void __w_template_copy(char* dst, char* src, int length):
	for i in range(length): dst[i] = src[i]


# Encode codepoint c as UTF-8 at out (negative values: one raw byte);
# returns the byte count.
int __w_template_utf8(char* out, int c):
	if (c < 128):
		out[0] = c
		return 1
	if (c < 2048):
		out[0] = 192 | (c >> 6)
		out[1] = 128 | (c & 63)
		return 2
	if (c < 65536):
		out[0] = 224 | (c >> 12)
		out[1] = 128 | ((c >> 6) & 63)
		out[2] = 128 | (c & 63)
		return 3
	out[0] = 240 | (c >> 18)
	out[1] = 128 | ((c >> 12) & 63)
	out[2] = 128 | ((c >> 6) & 63)
	out[3] = 128 | (c & 63)
	return 4


void __w_template_fill(string_builder* s, int fill, int count):
	while (count > 0):
		string_append_char(s, fill)
		count = count - 1


# Append length bytes of text padded to width display columns (UTF-8
# codepoints) for a '{value:spec}' interpolation. flags is
# fill << 8 | align: '<' pads after, '^' around, '=' between a leading
# sign and the digits (zero padding), anything else before.
void __w_template_pad(string_builder* s, char* text, int length, int width, int flags):
	int fill = flags >> 8
	int align = flags & 255
	int columns = 0
	for i in range(length):
		if ((text[i] & 192) != 128): columns = columns + 1
	int pad = width - columns
	if (pad < 0): pad = 0
	int before = pad
	if (align == '<'): before = 0
	if (align == '^'): before = pad / 2
	if ((align == '=') && (length > 0)):
		if ((text[0] == '-') || (text[0] == '+')):
			string_append_bytes(s, text, 1)
			text = text + 1
			length = length - 1
	__w_template_fill(s, fill, before)
	string_append_bytes(s, text, length)
	__w_template_fill(s, fill, pad - before)


# A spec'd int-like or text interpolation. kind: 0 decimal; 1 hex,
# 2 upper-case hex, 3 octal, 4 binary (the word's bits as unsigned);
# 5 a character (the value as a codepoint, UTF-8 encoded; negative
# values are raw bytes, which is what a char holding one byte of a
# UTF-8 sequence carries); 6 a char*; 7 a string descriptor.
void __w_template_fmt(string_builder* s, int value, int kind, int width, int precision, int flags):
	int size = 8 * __word_size__ + 2
	char* buffer = malloc(size)
	char* text = buffer
	int length = 0
	if (kind == 0):
		char* digits = itoa(value)
		length = strlen(digits)
		__w_template_copy(buffer, digits, length)
		free(digits)
	else if (kind <= 4):
		int shift = 4
		if (kind == 3): shift = 3
		if (kind == 4): shift = 1
		char* alphabet = c"0123456789abcdef"
		if (kind == 2): alphabet = c"0123456789ABCDEF"
		# '>>' is arithmetic: mask the shifted-in sign bits off
		int keep = (1 << (8 * __word_size__ - shift)) - 1
		int pos = size
		int v = value
		int more = 1
		while (more):
			pos = pos - 1
			buffer[pos] = alphabet[v & ((1 << shift) - 1)]
			v = (v >> shift) & keep
			more = v != 0
		text = buffer + pos
		length = size - pos
	else if (kind == 5): length = __w_template_utf8(buffer, value)
	else if (kind == 6):
		text = cast(char*, value)
		length = strlen(text)
	else:
		string v = cast(string, value)
		text = v.data
		length = v.length
	__w_template_pad(s, text, length, width, flags)
	free(buffer)


# '{value}' / '{value:spec}' of a float32: precision digits (6 when the
# spec gives none), rounded half up.
void __w_template_float(string_builder* s, float f, int width, int precision, int flags):
	if (precision < 0): precision = 6
	char* buffer = malloc(precision + 48)
	int pos = 0
	if (f < 0.0):
		buffer[pos] = '-'
		pos = pos + 1
		f = -f
	float half = 0.5
	int i = 0
	while (i < precision):
		half = half / 10.0
		i = i + 1
	f = f + half
	int whole = f
	char* digits = itoa(whole)
	__w_template_copy(buffer + pos, digits, strlen(digits))
	pos = pos + strlen(digits)
	free(digits)
	if (precision > 0):
		buffer[pos] = '.'
		pos = pos + 1
		float frac = f - whole
		i = 0
		while (i < precision):
			frac = frac * 10.0
			int digit = frac
			buffer[pos] = digit + '0'
			pos = pos + 1
			frac = frac - digit
			i = i + 1
	__w_template_pad(s, buffer, pos, width, flags)
	free(buffer)


void string_clear(string_builder* s):
	s.length = 0
	s.data[0] = 0


void string_free(string_builder* s):
	free(s.data)
	free(s)
