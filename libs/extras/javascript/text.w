# Owned JavaScript UTF-16 code units. Unlike char*, this retains NUL and lone
# surrogates. All lengths are code units, except explicitly named byte lengths.
import lib.utf8
import structures.string
import libs.extras.javascript.lexical


struct js_text:
	list[int] units


js_text* js_text_new():
	js_text* value = new js_text()
	value.units = new list[int]
	return value


void js_text_free(js_text* value):
	if (value == 0): return
	__w_list_free(cast(__w_list*, value.units))
	free(value)


void js_text_append_scalar(js_text* value, int cp):
	if (cp <= 65535): value.units.push(cp)
	else:
		cp = cp - 65536
		value.units.push(55296 + (cp >> 10))
		value.units.push(56320 + (cp & 1023))


js_text* js_text_clone(js_text* value):
	js_text* copy = js_text_new()
	for i in range(value.units.length): copy.units.push(value.units[i])
	return copy


int js_text_equal(js_text* a, js_text* b):
	if (a == 0 || b == 0): return a == b
	if (a.units.length != b.units.length): return 0
	for i in range(a.units.length):
		if (a.units[i] != b.units[i]): return 0
	return 1


# Strict UTF-8 conversion; rejects invalid bytes, accepts embedded NUL.
js_text* js_text_from_utf8(char* bytes, int length):
	if (length < 0 || (bytes == 0 && length != 0)): return 0
	js_text* value = js_text_new()
	int i = 0
	while (i < length):
		int cp = 0
		int width = utf8_scan(bytes + i, length - i, &cp)
		if (width == 0):
			js_text_free(value)
			return 0
		js_text_append_scalar(value, cp)
		i = i + width
	return value


# Owned UTF-8 plus a trailing NUL; *length includes embedded NUL bytes but
# excludes the terminator. Returns 0 for lone surrogates or invalid units.
char* js_text_to_utf8(js_text* value, int* length):
	*length = 0
	string_builder* out = string_new()
	int valid = 1
	int i = 0
	while (i < value.units.length):
		int cp = value.units[i]
		if (cp < 0 || cp > 65535):
			valid = 0
			break
		i = i + 1
		if (cp >= 55296 && cp <= 56319 && i < value.units.length):
			int low = value.units[i]
			if (low >= 56320 && low <= 57343):
				cp = 65536 + (cp - 55296) * 1024 + low - 56320
				i = i + 1
		if (cp < 0 || cp > 1114111 || (cp >= 55296 && cp <= 57343)):
			valid = 0
			break
		char[4] encoded
		int width = utf8_encode(encoded, cp)
		string_append_bytes(out, encoded, width)
	if (valid == 0):
		string_free(out)
		return 0
	char* result = out.data
	*length = out.length
	free(out)
	return result


# Decode a complete quoted source token, never treating an input boundary as
# an implicit terminator. Lexer helpers see an owned NUL-terminated copy.
js_text* js_text_decode(char* bytes, int length):
	if (bytes == 0 || length < 2 || (bytes[0] != 39 && bytes[0] != 34) || bytes[length - 1] != bytes[0]): return 0
	char* raw = cast(char*, malloc(length + 1))
	for j in range(length): raw[j] = bytes[j]
	raw[length] = 0
	js_text* value = js_text_new()
	int i = 1
	int limit = length - 1
	int valid = 1
	while (valid && i < limit):
		int cp = raw[i] & 255
		if (cp != 92):
			int width = utf8_scan(raw + i, limit - i, &cp)
			if (width == 0 || cp == raw[0] || cp == 10 || cp == 13):
				valid = 0
				break
			js_text_append_scalar(value, cp)
			i = i + width
			continue
		int start = i
		i = i + 1
		if (i >= limit):
			valid = 0
			break
		int n = js_line_terminator(raw, i)
		if (n > 0):
			if (raw[i] == 13 && raw[i + 1] == 10): n = 2
			i = i + n
			continue
		int ch = raw[i] & 255
		if (ch >= 128):
			int width = utf8_scan(raw + i, limit - i, &cp)
			if (width == 0):
				valid = 0
				break
			js_text_append_scalar(value, cp)
			i = i + width
			continue
		cp = ch
		if (ch == 'u'):
			n = js_unicode_escape(raw, start, &cp)
			if (n == 0 || start + n > limit):
				valid = 0
				break
			i = start + n
		else if (ch == 'x'):
			if (i + 2 >= limit || js_hex(raw[i + 1]) < 0 || js_hex(raw[i + 2]) < 0):
				valid = 0
				break
			cp = js_hex(raw[i + 1]) * 16 + js_hex(raw[i + 2])
			i = i + 3
		else:
			i = i + 1
			if (ch == 'n'): cp = 10
			else if (ch == 'r'): cp = 13
			else if (ch == 't'): cp = 9
			else if (ch == 'b'): cp = 8
			else if (ch == 'f'): cp = 12
			else if (ch == 'v'): cp = 11
			else if (ch >= '0' && ch <= '7'):
				cp = ch - '0'
				int count = 1
				while (count < 3 && i < limit && raw[i] >= '0' && raw[i] <= '7'):
					if (count == 2 && cp > 31): break
					cp = cp * 8 + raw[i] - '0'
					i = i + 1
					count = count + 1
		js_text_append_scalar(value, cp)
	free(raw)
	if (valid == 0):
		js_text_free(value)
		return 0
	return value
