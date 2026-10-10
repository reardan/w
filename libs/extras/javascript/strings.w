# Decode quoted JavaScript strings for the owned AST and module-specifier edits.
# The char* consumer API cannot represent embedded NUL or lone UTF-16 surrogates;
# report those explicitly. The parser retains their valid original spelling.
import lib.utf8
import structures.string
import libs.extras.javascript.lexical


char* js_string_decode(char* raw, pg_diagnostics* diagnostics):
	string_builder* out = string_new()
	int limit = strlen(raw) - 1
	int i = 1
	int valid = limit >= 1 && (raw[0] == 39 || raw[0] == 34)
	while (valid && i < limit):
		int ch = raw[i] & 255
		if (ch != 92):
			string_append_char(out, ch)
			i = i + 1
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
		ch = raw[i]
		int cp = ch
		if (ch == 'u'):
			n = js_unicode_escape(raw, start, &cp)
			if (n == 0):
				valid = 0
				break
			i = start + n
			if (cp >= 55296 && cp <= 56319):
				int low = 0
				int width = js_unicode_escape(raw, i, &low)
				if (width == 0 || low < 56320 || low > 57343):
					valid = 0
					break
				cp = 65536 + (cp - 55296) * 1024 + low - 56320
				i = i + width
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
				while (count < 3 && raw[i] >= '0' && raw[i] <= '7'):
					if (count == 2 && cp > 31): break
					cp = cp * 8 + raw[i] - '0'
					i = i + 1
					count = count + 1
		if (cp == 0 || (cp >= 55296 && cp <= 57343)):
			valid = 0
			break
		char[4] encoded
		int width = utf8_encode(encoded, cp)
		string_append_bytes(out, encoded, width)
	if (valid == 0):
		pg_diagnostics_add(diagnostics, c"<JavaScript string>", 1, 1, c"string cannot be represented by this char* AST API", c"non-NUL Unicode scalar values", raw)
		string_free(out)
		return 0
	char* result = out.data
	free(out)
	return result
