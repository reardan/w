/*
libs.standard.formats.toml: a TOML 1.0 reader (Python's tomllib).

toml_parse(text) parses a whole document into the same tree type
structures/json.w builds, so callers walk one tree type:

- a table (the root, [headers], dotted-key parents, inline tables) is
  a json object; members keep their document order
- an array (static or array of tables) is a json array
- a string is a json string
- an integer is a json int. TOML integers are 64-bit; on 8-byte-word
  targets every TOML integer fits, while on 4-byte-word targets (x86,
  wasm32) a value outside the native int32 range is a parse error
  ("integer out of range"), as the spec requires of an implementation
  that cannot represent it, rather than a silent truncation
- a float is a json float built the way json_parse builds one:
  float_value holds the correctly rounded float32, and on 8-byte-word
  targets float64_bits/has_float64 carry the correctly rounded float64.
  inf, -inf and nan are kept (json_stringify writes them as null)
- a boolean is a json bool
- an offset date-time, local date-time, local date or local time is a
  json string holding its validated RFC 3339 text, with the date/time
  separator normalized to 'T' and a 'z' offset to 'Z'. json_value has
  no datetime type, so the string's otherwise unused int_value carries
  which TOML kind it is: toml_string_kind() returns toml_kind_string (0)
  for ordinary strings, else one of the toml_kind_* datetime constants.
  (json_clone does not copy that tag.) A later datetime chunk can map
  these onto real datetime values.

Integers and floats therefore stay distinct (json_type_int vs
json_type_float), exactly as tomllib returns int vs float.

Errors carry the 1-based line and column (in code points) of the
offending character: doc.root is 0 and doc.error reads
"line L, column C: message"; doc.line/doc.column hold the numbers.
Input must be valid UTF-8 (a leading BOM is skipped). Strings are
decoded fully: escapes \b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX (to
UTF-8; surrogates and values past U+10FFFF are errors), multi-line
basic strings with line-ending backslashes, literal and multi-line
literal strings; CRLF inside multi-line strings reads as LF.

Read-only like tomllib; there is no writer. toml_tagged_json() renders a
tree in toml-test's tagged-JSON form ({"type": ..., "value": ...}
leaves) so the reader can be driven by toml-test's decoder harness.
*/
import lib.lib
import structures.string
import structures.json
import lib.float_text


struct toml_doc:
	json_value* root
	char* error
	int line
	int column


struct toml_parser:
	char* src
	int pos
	int ok
	char* message
	int err_pos
	json_value* root
	json_value* current


# Datetime kinds carried in a string value's int_value.
const int toml_kind_string = 0
const int toml_kind_offset_datetime = 1
const int toml_kind_local_datetime = 2
const int toml_kind_local_date = 3
const int toml_kind_local_time = 4

# Parse-time table/array flags, kept in the container's (otherwise
# unused) int_value and cleared before the tree is returned.
const int toml_flag_explicit = 1      # defined by a [header]
const int toml_flag_implicit = 2      # created as a header's parent
const int toml_flag_dotted = 4        # created by a dotted key
const int toml_flag_frozen = 8        # inline table or static array
const int toml_flag_aot = 16          # array of tables ([[header]])

const int toml_max_depth = 128


json_value* toml_parse_value(toml_parser* p, int depth);
void toml_parse_keyval(toml_parser* p, json_value* table, int depth);


void toml_fail_at(toml_parser* p, int pos, char* message):
	if (p.ok == 0): return
	p.ok = 0
	p.err_pos = pos
	p.message = message


void toml_fail(toml_parser* p, char* message):
	toml_fail_at(p, p.pos, message)


int toml_is_digit(int c):
	return (c >= '0') && (c <= '9')


int toml_is_bare_key_char(int c):
	if ((c >= 'a') && (c <= 'z')): return 1
	if ((c >= 'A') && (c <= 'Z')): return 1
	return toml_is_digit(c) || (c == '_') || (c == '-')


# Control characters TOML forbids in strings and comments (tab is fine).
int toml_is_control(int c):
	return ((c >= 0) && (c < 32) && (c != '\t')) || (c == 127)


int toml_string_kind(json_value* value):
	if (value == 0): return toml_kind_string
	if (value.type != json_type_string()): return toml_kind_string
	return value.int_value


# Reject malformed UTF-8 (overlong forms, surrogates, > U+10FFFF).
void toml_check_utf8(toml_parser* p):
	char* s = p.src
	int i = 0
	while (s[i] != 0):
		int c = s[i] & 255
		if (c < 0x80):
			i = i + 1
		else:
			int n = 0
			int cp = 0
			int low = 0
			if ((c >= 0xc2) && (c <= 0xdf)):
				n = 1
				cp = c & 0x1f
				low = 0x80
			else if ((c >= 0xe0) && (c <= 0xef)):
				n = 2
				cp = c & 0x0f
				low = 0x800
			else if ((c >= 0xf0) && (c <= 0xf4)):
				n = 3
				cp = c & 7
				low = 0x10000
			else:
				toml_fail_at(p, i, c"invalid UTF-8")
				return
			int k = 1
			while (k <= n):
				int b = s[i + k] & 255
				if ((b & 0xc0) != 0x80):
					toml_fail_at(p, i, c"invalid UTF-8")
					return
				cp = (cp << 6) | (b & 0x3f)
				k = k + 1
			if ((cp < low) || (cp > 0x10ffff) || ((cp >= 0xd800) && (cp <= 0xdfff))):
				toml_fail_at(p, i, c"invalid UTF-8")
				return
			i = i + n + 1


void toml_skip_ws(toml_parser* p):
	while ((p.src[p.pos] == ' ') || (p.src[p.pos] == '\t')): p.pos = p.pos + 1


# Consume one newline (LF or CRLF); 1 when there was one.
int toml_take_newline(toml_parser* p):
	if (p.src[p.pos] == '\n'):
		p.pos = p.pos + 1
		return 1
	if (p.src[p.pos] == '\r'):
		if (p.src[p.pos + 1] == '\n'):
			p.pos = p.pos + 2
			return 1
	return 0


# With p.pos on '#': skip the comment up to (not including) its newline.
void toml_skip_comment(toml_parser* p):
	p.pos = p.pos + 1
	while (p.ok):
		int c = p.src[p.pos]
		if ((c == 0) || (c == '\n')): return
		if (c == '\r'):
			if (p.src[p.pos + 1] == '\n'): return
			toml_fail(p, c"bare carriage return in comment")
			return
		if (toml_is_control(c)):
			toml_fail(p, c"control character in comment")
			return
		p.pos = p.pos + 1


# Finish a line: optional whitespace and comment, then a newline or EOF.
void toml_end_line(toml_parser* p, char* message):
	toml_skip_ws(p)
	if (p.src[p.pos] == '#'): toml_skip_comment(p)
	if (p.ok == 0): return
	if (p.src[p.pos] == 0): return
	if (toml_take_newline(p) == 0):
		if (p.src[p.pos] == '\r'): toml_fail(p, c"bare carriage return")
		else: toml_fail(p, message)


# Whitespace, newlines and comments, as allowed between array elements.
void toml_skip_ws_lines(toml_parser* p):
	while (p.ok):
		toml_skip_ws(p)
		if (p.src[p.pos] == '#'): toml_skip_comment(p)
		else if (toml_take_newline(p) == 0):
			if (p.src[p.pos] == '\r'): toml_fail(p, c"bare carriage return")
			return


char* toml_take_builder(string_builder* s):
	char* data = s.data
	free(s)
	return data


# One escape sequence with p.pos on the backslash.
void toml_parse_escape(toml_parser* p, string_builder* out):
	int e = p.src[p.pos + 1]
	if (e == 'b'): string_append_char(out, 8)
	else if (e == 't'): string_append_char(out, '\t')
	else if (e == 'n'): string_append_char(out, '\n')
	else if (e == 'f'): string_append_char(out, 12)
	else if (e == 'r'): string_append_char(out, '\r')
	else if (e == '"'): string_append_char(out, '"')
	else if (e == '\\'): string_append_char(out, '\\')
	else if ((e == 'u') || (e == 'U')):
		int n = 4
		if (e == 'U'): n = 8
		int cp = 0
		int k = 0
		while (k < n):
			int d = json_hex_value(p.src[p.pos + 2 + k])
			if (d < 0):
				toml_fail(p, c"invalid unicode escape: expected hex digits")
				return
			# stop accumulating once out of range so 8 digits never overflow
			if (cp <= 0x10ffff): cp = cp * 16 + d
			k = k + 1
		if ((cp > 0x10ffff) || ((cp >= 0xd800) && (cp <= 0xdfff))):
			toml_fail(p, c"unicode escape is not a Unicode scalar value")
			return
		json_append_utf8(out, cp)
		p.pos = p.pos + 2 + n
		return
	else:
		toml_fail(p, c"invalid escape sequence")
		return
	p.pos = p.pos + 2


# Single-line basic ("...") or literal ('...') string, p.pos on the quote.
char* toml_parse_line_string(toml_parser* p, int quote):
	int start = p.pos
	p.pos = p.pos + 1
	string_builder* out = string_new()
	while (p.ok):
		int c = p.src[p.pos]
		if (c == quote):
			p.pos = p.pos + 1
			return toml_take_builder(out)
		if ((c == 0) || (c == '\n') || (c == '\r')):
			toml_fail_at(p, start, c"unterminated string")
		else if ((c == '\\') && (quote == '"')):
			toml_parse_escape(p, out)
		else if (toml_is_control(c)):
			toml_fail(p, c"control character in string")
		else:
			string_append_char(out, c)
			p.pos = p.pos + 1
	string_free(out)
	return 0


# Multi-line basic ("""...""") or literal ('''...''') string, p.pos on
# the first of the three opening quotes.
char* toml_parse_multiline_string(toml_parser* p, int quote):
	int start = p.pos
	p.pos = p.pos + 3
	toml_take_newline(p)
	string_builder* out = string_new()
	while (p.ok):
		int c = p.src[p.pos]
		if (c == 0):
			toml_fail_at(p, start, c"unterminated multi-line string")
		else if ((c == quote) && (p.src[p.pos + 1] == quote) && (p.src[p.pos + 2] == quote)):
			int n = 3
			while (p.src[p.pos + n] == quote): n = n + 1
			if (n > 5):
				toml_fail(p, c"too many quotes at the end of a multi-line string")
			else:
				int k = 3
				while (k < n):
					string_append_char(out, quote)
					k = k + 1
				p.pos = p.pos + n
				return toml_take_builder(out)
		else if ((c == '\\') && (quote == '"')):
			int j = p.pos + 1
			while ((p.src[j] == ' ') || (p.src[j] == '\t')): j = j + 1
			int ends_line = p.src[j] == '\n'
			if (p.src[j] == '\r'): ends_line = p.src[j + 1] == '\n'
			if (ends_line):
				# line-ending backslash: drop it and all following whitespace
				p.pos = j
				int more = 1
				while (more):
					int w = p.src[p.pos]
					if ((w == ' ') || (w == '\t')): p.pos = p.pos + 1
					else: more = toml_take_newline(p)
			else:
				toml_parse_escape(p, out)
		else if (c == '\n'):
			string_append_char(out, '\n')
			p.pos = p.pos + 1
		else if (c == '\r'):
			if (toml_take_newline(p)): string_append_char(out, '\n')
			else: toml_fail(p, c"bare carriage return in string")
		else if (toml_is_control(c)):
			toml_fail(p, c"control character in string")
		else:
			string_append_char(out, c)
			p.pos = p.pos + 1
	string_free(out)
	return 0


char* toml_parse_simple_key(toml_parser* p):
	int c = p.src[p.pos]
	if (c == '"'): return toml_parse_line_string(p, '"')
	if (c == '\''): return toml_parse_line_string(p, '\'')
	if (toml_is_bare_key_char(c) == 0):
		toml_fail(p, c"expected a key")
		return 0
	int start = p.pos
	while (toml_is_bare_key_char(p.src[p.pos])): p.pos = p.pos + 1
	string_builder* out = string_new()
	string_append_bytes(out, &p.src[start], p.pos - start)
	return toml_take_builder(out)


void toml_free_key(list[char*] key):
	if (key == 0): return
	for char* part in key: free(part)
	list_free[char*](key)


# A possibly dotted key; 0 after a failure.
list[char*] toml_parse_key(toml_parser* p):
	list[char*] key = new list[char*]
	while (p.ok):
		toml_skip_ws(p)
		char* part = toml_parse_simple_key(p)
		if (p.ok == 0):
			toml_free_key(key)
			return 0
		key.push(part)
		toml_skip_ws(p)
		if (p.src[p.pos] != '.'): return key
		p.pos = p.pos + 1
	toml_free_key(key)
	return 0


void toml_freeze(json_value* value):
	if (value.type == json_type_object()):
		value.int_value = value.int_value | toml_flag_frozen
		for char* key, json_value* member in value.object_values: toml_freeze(member)
	else if (value.type == json_type_array()):
		value.int_value = value.int_value | toml_flag_frozen
		for json_value* element in value.array_values: toml_freeze(element)


void toml_clear_flags(json_value* value):
	if (value.type == json_type_object()):
		value.int_value = 0
		for char* key, json_value* member in value.object_values: toml_clear_flags(member)
	else if (value.type == json_type_array()):
		value.int_value = 0
		for json_value* element in value.array_values: toml_clear_flags(element)


# Store value under a (dotted) key in table, creating the dotted
# parents. Takes ownership of value, freeing it on failure.
void toml_insert_dotted(toml_parser* p, json_value* table, list[char*] key, json_value* value, int key_pos):
	json_value* t = table
	int last = key.length - 1
	int i = 0
	while (i < last):
		json_value* child = json_object_get(t, key[i])
		if (child == 0):
			child = json_object()
			child.int_value = toml_flag_dotted
			json_object_set(t, key[i], child)
		else if (child.type != json_type_object()):
			toml_fail_at(p, key_pos, c"dotted key goes through a key that is not a table")
		else if (((child.int_value & toml_flag_dotted) == 0) || (child.int_value & toml_flag_frozen)):
			toml_fail_at(p, key_pos, c"dotted key cannot extend a table defined elsewhere")
		if (p.ok == 0):
			json_free(value)
			return
		t = child
		i = i + 1
	if (json_object_has(t, key[last])):
		toml_fail_at(p, key_pos, c"duplicate key")
		json_free(value)
		return
	json_object_set(t, key[last], value)


void toml_parse_keyval(toml_parser* p, json_value* table, int depth):
	int key_pos = p.pos
	list[char*] key = toml_parse_key(p)
	if (p.ok == 0): return
	toml_skip_ws(p)
	if (p.src[p.pos] != '='):
		toml_fail(p, c"expected '=' after key")
		toml_free_key(key)
		return
	p.pos = p.pos + 1
	toml_skip_ws(p)
	json_value* value = toml_parse_value(p, depth)
	if (p.ok == 0):
		json_free(value)
		toml_free_key(key)
		return
	toml_insert_dotted(p, table, key, value, key_pos)
	toml_free_key(key)


json_value* toml_parse_array(toml_parser* p, int depth):
	json_value* array = json_array()
	p.pos = p.pos + 1
	while (p.ok):
		toml_skip_ws_lines(p)
		if (p.ok == 0): return array
		if (p.src[p.pos] == ']'):
			p.pos = p.pos + 1
			toml_freeze(array)
			return array
		json_value* element = toml_parse_value(p, depth + 1)
		if (p.ok == 0):
			json_free(element)
			return array
		json_array_push(array, element)
		toml_skip_ws_lines(p)
		if (p.ok == 0): return array
		if (p.src[p.pos] == ','): p.pos = p.pos + 1
		else if (p.src[p.pos] == ']'):
			p.pos = p.pos + 1
			toml_freeze(array)
			return array
		else if (p.src[p.pos] == 0): toml_fail(p, c"unterminated array")
		else: toml_fail(p, c"expected ',' or ']' in array")
	return array


json_value* toml_parse_inline_table(toml_parser* p, int depth):
	json_value* table = json_object()
	p.pos = p.pos + 1
	toml_skip_ws(p)
	if (p.src[p.pos] == '}'):
		p.pos = p.pos + 1
		toml_freeze(table)
		return table
	while (p.ok):
		toml_skip_ws(p)
		if (p.src[p.pos] == '}'):
			toml_fail(p, c"trailing comma in inline table")
			return table
		toml_parse_keyval(p, table, depth + 1)
		if (p.ok == 0): return table
		toml_skip_ws(p)
		int c = p.src[p.pos]
		if (c == ','): p.pos = p.pos + 1
		else if (c == '}'):
			p.pos = p.pos + 1
			toml_freeze(table)
			return table
		else if ((c == '\n') || (c == '\r')): toml_fail(p, c"newline in inline table")
		else if (c == 0): toml_fail(p, c"unterminated inline table")
		else: toml_fail(p, c"expected ',' or '}' in inline table")
	return table


# Value of n digits at s[at..], or -1 if any is not a digit.
int toml_dt_digits(char* s, int at, int n):
	int value = 0
	int k = 0
	while (k < n):
		int c = s[at + k]
		if (toml_is_digit(c) == 0): return -1
		value = value * 10 + c - '0'
		k = k + 1
	return value


int toml_days_in_month(int year, int month):
	if (month == 2):
		int leap = ((year % 4) == 0) && (((year % 100) != 0) || ((year % 400) == 0))
		if (leap): return 29
		return 28
	if ((month == 4) || (month == 6) || (month == 9) || (month == 11)): return 30
	return 31


# Validate HH:MM:SS(.frac)? at s[at]; the index after it, or -1.
int toml_dt_time(char* s, int at):
	int h = toml_dt_digits(s, at, 2)
	if ((h < 0) || (h > 23) || (s[at + 2] != ':')): return -1
	int m = toml_dt_digits(s, at + 3, 2)
	if ((m < 0) || (m > 59) || (s[at + 5] != ':')): return -1
	int sec = toml_dt_digits(s, at + 6, 2)
	if ((sec < 0) || (sec > 59)): return -1
	int j = at + 8
	if (s[j] == '.'):
		j = j + 1
		if (toml_is_digit(s[j]) == 0): return -1
		while (toml_is_digit(s[j])): j = j + 1
	return j


# Validate a date/time token in place (normalizing its separator and
# 'z'); its toml_kind_*, or -1 when it is malformed.
int toml_dt_validate(char* s):
	if ((toml_is_digit(s[0])) && (toml_is_digit(s[1])) && (s[2] == ':')):
		int end = toml_dt_time(s, 0)
		if ((end < 0) || (s[end] != 0)): return -1
		return toml_kind_local_time
	int y = toml_dt_digits(s, 0, 4)
	if ((y < 0) || (s[4] != '-')): return -1
	int mo = toml_dt_digits(s, 5, 2)
	if ((mo < 1) || (mo > 12) || (s[7] != '-')): return -1
	int d = toml_dt_digits(s, 8, 2)
	if ((d < 1) || (d > toml_days_in_month(y, mo))): return -1
	if (s[10] == 0): return toml_kind_local_date
	if ((s[10] != 'T') && (s[10] != 't') && (s[10] != ' ')): return -1
	s[10] = 'T'
	int j = toml_dt_time(s, 11)
	if (j < 0): return -1
	if (s[j] == 0): return toml_kind_local_datetime
	if ((s[j] == 'Z') || (s[j] == 'z')):
		s[j] = 'Z'
		j = j + 1
	else if ((s[j] == '+') || (s[j] == '-')):
		int oh = toml_dt_digits(s, j + 1, 2)
		if ((oh < 0) || (oh > 23) || (s[j + 3] != ':')): return -1
		int om = toml_dt_digits(s, j + 4, 2)
		if ((om < 0) || (om > 59)): return -1
		j = j + 6
	else: return -1
	if (s[j] != 0): return -1
	return toml_kind_offset_datetime


# Digits of the given base at t[i] with single underscores allowed
# between digits, appended to clean; the index after them, or -1.
int toml_scan_digits(char* t, int i, int base, string_builder* clean):
	int first = json_hex_value(t[i])
	if ((first < 0) || (first >= base)): return -1
	while (1):
		int c = t[i]
		int d = json_hex_value(c)
		if ((d >= 0) && (d < base)):
			string_append_char(clean, c)
			i = i + 1
		else if (c == '_'):
			d = json_hex_value(t[i + 1])
			if ((d < 0) || (d >= base)): return -1
			i = i + 1
		else: return i
	return i


int toml_int_min():
	int low = 1
	while (low > 0): low = low << 1
	return low


json_value* toml_make_float(char* text):
	float m
	int32* m_bits = cast(int32*, &m)
	*m_bits = float_text_parse(text, 32, 0)
	json_value* value = json_float(m)
	if (__word_size__ == 8):
		value.float64_bits = float_text_parse(text, 64, 0)
		value.has_float64 = 1
	return value


# Integer or float token t (from p.src at start).
json_value* toml_parse_number_token(toml_parser* p, char* t, int start):
	int i = 0
	int negative = 0
	int signed = 0
	if ((t[0] == '+') || (t[0] == '-')):
		signed = 1
		negative = t[0] == '-'
		i = 1
	if ((strcmp(&t[i], c"inf") == 0) || (strcmp(&t[i], c"nan") == 0)):
		return toml_make_float(t)
	string_builder* clean = string_new()
	int base = 10
	if ((t[i] == '0') && ((t[i + 1] == 'x') || (t[i + 1] == 'o') || (t[i + 1] == 'b'))):
		if (t[i + 1] == 'x'): base = 16
		else if (t[i + 1] == 'o'): base = 8
		else: base = 2
		if (signed):
			string_free(clean)
			toml_fail_at(p, start, c"sign not allowed on hex, octal or binary integers")
			return 0
		i = i + 2
	int is_float = 0
	int j = toml_scan_digits(t, i, base, clean)
	if (j < 0):
		string_free(clean)
		toml_fail_at(p, start, c"invalid number")
		return 0
	if ((base == 10) && (t[i] == '0') && (j - i > 1)):
		string_free(clean)
		toml_fail_at(p, start, c"leading zeros are not allowed")
		return 0
	if (base == 10):
		if (t[j] == '.'):
			is_float = 1
			string_append_char(clean, '.')
			j = toml_scan_digits(t, j + 1, 10, clean)
		if ((j >= 0) && ((t[j] == 'e') || (t[j] == 'E'))):
			is_float = 1
			string_append_char(clean, 'e')
			j = j + 1
			if ((t[j] == '+') || (t[j] == '-')):
				string_append_char(clean, t[j])
				j = j + 1
			j = toml_scan_digits(t, j, 10, clean)
	if ((j < 0) || (t[j] != 0)):
		string_free(clean)
		toml_fail_at(p, start, c"invalid number")
		return 0
	char* digits = toml_take_builder(clean)
	if (is_float):
		string_builder* full = string_new()
		if (negative): string_append_char(full, '-')
		string_append(full, digits)
		free(digits)
		char* text = toml_take_builder(full)
		json_value* f = toml_make_float(text)
		free(text)
		return f
	# accumulate as a negative number so the most negative value fits
	int low = toml_int_min()
	int value = 0
	int k = 0
	int overflow = 0
	while ((digits[k] != 0) && (overflow == 0)):
		int d = json_hex_value(digits[k])
		if (value < (low + d) / base): overflow = 1
		else: value = value * base - d
		k = k + 1
	if ((overflow == 0) && (negative == 0)):
		if (value == low): overflow = 1
		else: value = 0 - value
	free(digits)
	if (overflow):
		toml_fail_at(p, start, c"integer out of range")
		return 0
	return json_int(value)


# A number, date or time token starting at p.pos.
json_value* toml_parse_scalar(toml_parser* p):
	int start = p.pos
	while (1):
		int c = p.src[p.pos]
		if (toml_is_bare_key_char(c) || (c == '+') || (c == '.') || (c == ':')): p.pos = p.pos + 1
		else if ((c == ' ') && (p.pos - start == 10) && (p.src[start + 4] == '-') && toml_is_digit(p.src[p.pos + 1]) && toml_is_digit(p.src[p.pos + 2]) && (p.src[p.pos + 3] == ':')):
			# "1979-05-27 07:32:00": a space may separate date and time
			p.pos = p.pos + 1
		else: break
	string_builder* sb = string_new()
	string_append_bytes(sb, &p.src[start], p.pos - start)
	char* t = toml_take_builder(sb)
	int is_time = toml_is_digit(t[0]) && toml_is_digit(t[1]) && (t[2] == ':')
	int is_date = toml_is_digit(t[0]) && toml_is_digit(t[1]) && toml_is_digit(t[2]) && toml_is_digit(t[3]) && (t[4] == '-')
	if (is_time || is_date):
		int kind = toml_dt_validate(t)
		if (kind < 0):
			free(t)
			toml_fail_at(p, start, c"invalid date or time")
			return 0
		json_value* value = json_string_take(t)
		value.int_value = kind
		return value
	json_value* number = toml_parse_number_token(p, t, start)
	free(t)
	return number


int toml_match_word(toml_parser* p, char* word):
	int i = 0
	while (word[i] != 0):
		if (p.src[p.pos + i] != word[i]): return 0
		i = i + 1
	p.pos = p.pos + i
	return 1


json_value* toml_parse_value(toml_parser* p, int depth):
	if (depth >= toml_max_depth):
		toml_fail(p, c"nesting too deep")
		return 0
	int c = p.src[p.pos]
	if ((c == '"') || (c == '\'')):
		char* text = 0
		if ((p.src[p.pos + 1] == c) && (p.src[p.pos + 2] == c)): text = toml_parse_multiline_string(p, c)
		else: text = toml_parse_line_string(p, c)
		if (p.ok == 0): return 0
		return json_string_take(text)
	if (c == '['): return toml_parse_array(p, depth)
	if (c == '{'): return toml_parse_inline_table(p, depth)
	if (c == 't'):
		if (toml_match_word(p, c"true")): return json_bool(1)
	if (c == 'f'):
		if (toml_match_word(p, c"false")): return json_bool(0)
	if (toml_is_digit(c) || (c == '+') || (c == '-') || (c == 'i') || (c == 'n')):
		return toml_parse_scalar(p)
	if ((c == 0) || (c == '\n') || (c == '\r') || (c == '#')): toml_fail(p, c"expected a value")
	else: toml_fail(p, c"invalid value")
	return 0


# [table] or [[array of tables]] with p.pos on the first '['.
void toml_parse_header(toml_parser* p):
	int header_pos = p.pos
	p.pos = p.pos + 1
	int is_aot = p.src[p.pos] == '['
	if (is_aot): p.pos = p.pos + 1
	list[char*] key = toml_parse_key(p)
	if (p.ok == 0): return
	if (p.src[p.pos] != ']'): toml_fail(p, c"expected ']' after table name")
	else:
		p.pos = p.pos + 1
		if (is_aot):
			if (p.src[p.pos] != ']'): toml_fail(p, c"expected ']]' after array of tables name")
			else: p.pos = p.pos + 1
	if (p.ok == 0):
		toml_free_key(key)
		return
	json_value* t = p.root
	int last = key.length - 1
	int i = 0
	while ((i < last) && p.ok):
		json_value* child = json_object_get(t, key[i])
		if (child == 0):
			child = json_object()
			child.int_value = toml_flag_implicit
			json_object_set(t, key[i], child)
		else if (child.type == json_type_object()):
			if (child.int_value & toml_flag_frozen): toml_fail_at(p, header_pos, c"cannot extend an inline table")
		else if (child.type == json_type_array()):
			if ((child.int_value & toml_flag_aot) == 0): toml_fail_at(p, header_pos, c"cannot extend a static array")
			else: child = json_array_get(child, json_array_length(child) - 1)
		else: toml_fail_at(p, header_pos, c"key already defined as a value")
		t = child
		i = i + 1
	if (p.ok == 0):
		toml_free_key(key)
		return
	json_value* found = json_object_get(t, key[last])
	if (is_aot):
		if (found == 0):
			found = json_array()
			found.int_value = toml_flag_aot
			json_object_set(t, key[last], found)
		else if ((found.type != json_type_array()) || ((found.int_value & toml_flag_aot) == 0)):
			toml_fail_at(p, header_pos, c"key already defined; cannot make it an array of tables")
		if (p.ok):
			json_value* element = json_object()
			element.int_value = toml_flag_explicit
			json_array_push(found, element)
			p.current = element
	else:
		if (found == 0):
			found = json_object()
			json_object_set(t, key[last], found)
		else if ((found.type != json_type_object()) || ((found.int_value & (toml_flag_explicit | toml_flag_dotted | toml_flag_frozen)) != 0)):
			toml_fail_at(p, header_pos, c"table redefined")
		if (p.ok):
			found.int_value = toml_flag_explicit
			p.current = found
	toml_free_key(key)


void toml_parse_document(toml_parser* p):
	# skip a UTF-8 byte order mark
	if (((p.src[0] & 255) == 0xef) && ((p.src[1] & 255) == 0xbb) && ((p.src[2] & 255) == 0xbf)): p.pos = 3
	while (p.ok):
		toml_skip_ws(p)
		int c = p.src[p.pos]
		if (c == 0): return
		if ((c == '#') || (c == '\n') || (c == '\r')):
			toml_end_line(p, c"expected a newline")
		else if (c == '['):
			toml_parse_header(p)
			if (p.ok): toml_end_line(p, c"expected a newline after table header")
		else:
			toml_parse_keyval(p, p.current, 0)
			if (p.ok): toml_end_line(p, c"expected a newline after value")


# Parse a TOML document. Always returns a doc: on success doc.root owns
# the tree (doc.error == 0); on failure doc.root is 0 and doc.error,
# doc.line and doc.column describe the first error. Free with
# toml_doc_free (after toml_doc_take_root to keep the tree).
toml_doc* toml_parse(char* text):
	toml_parser* p = new toml_parser()
	p.src = text
	p.pos = 0
	p.ok = 1
	p.message = 0
	p.err_pos = 0
	p.root = json_object()
	p.current = p.root
	toml_check_utf8(p)
	if (p.ok): toml_parse_document(p)
	toml_doc* doc = new toml_doc()
	doc.root = 0
	doc.error = 0
	doc.line = 0
	doc.column = 0
	if (p.ok):
		toml_clear_flags(p.root)
		doc.root = p.root
	else:
		json_free(p.root)
		int line = 1
		int column = 1
		int i = 0
		while (i < p.err_pos):
			int c = text[i]
			if (c == '\n'):
				line = line + 1
				column = 1
			else if ((c & 0xc0) != 0x80): column = column + 1
			i = i + 1
		doc.line = line
		doc.column = column
		string_builder* msg = string_new()
		string_append(msg, c"line ")
		string_append_int(msg, line)
		string_append(msg, c", column ")
		string_append_int(msg, column)
		string_append(msg, c": ")
		string_append(msg, p.message)
		doc.error = toml_take_builder(msg)
	free(p)
	return doc


# Hand the tree to the caller; the doc no longer frees it.
json_value* toml_doc_take_root(toml_doc* doc):
	json_value* root = doc.root
	doc.root = 0
	return root


void toml_doc_free(toml_doc* doc):
	if (doc == 0): return
	json_free(doc.root)
	if (doc.error): free(doc.error)
	free(doc)


# Parse and return the root table (caller frees with json_free), or 0
# when the document is invalid.
json_value* toml_loads(char* text):
	toml_doc* doc = toml_parse(text)
	json_value* root = toml_doc_take_root(doc)
	toml_doc_free(doc)
	return root


# Look up a TOML key (dotted, with quoted parts allowed, e.g.
# c"servers.\"alpha.1\".ip") starting at table; a borrowed pointer, or 0
# when missing, malformed or passing through a non-table.
json_value* toml_get(json_value* table, char* dotted_key):
	if (table == 0): return 0
	toml_parser* p = new toml_parser()
	p.src = dotted_key
	p.pos = 0
	p.ok = 1
	list[char*] key = toml_parse_key(p)
	int ok = p.ok && (p.src[p.pos] == 0)
	free(p)
	if (ok == 0):
		toml_free_key(key)
		return 0
	json_value* t = table
	for char* part in key:
		if ((t != 0) && (t.type == json_type_object())): t = json_object_get(t, part)
		else: t = 0
	toml_free_key(key)
	return t


void toml_append_tagged(string_builder* out, json_value* value);


void toml_append_leaf(string_builder* out, char* type, char* text):
	string_append(out, c"{\"type\":")
	json_append_escaped_string(out, type)
	string_append(out, c",\"value\":")
	json_append_escaped_string(out, text)
	string_append_char(out, '}')


void toml_append_tagged_float(string_builder* out, json_value* value):
	int width = 32
	int bits = json_float_bits(value.float_value)
	if (value.has_float64):
		width = 64
		bits = value.float64_bits
	string_builder* text = string_new()
	if (float_text_is_special(bits, width)):
		int one = 1
		int frac = bits & ((one << 23) - 1)
		int negative = (bits >> 31) & 1
		if (width == 64):
			frac = bits & ((one << (width - 12)) - 1)
			negative = bits < 0
		if (frac != 0): string_append(text, c"nan")
		else if (negative): string_append(text, c"-inf")
		else: string_append(text, c"inf")
	else: json_append_float_bits(text, bits, width)
	toml_append_leaf(out, c"float", text.data)
	string_free(text)


void toml_append_tagged(string_builder* out, json_value* value):
	if (value.type == json_type_object()):
		string_append_char(out, '{')
		int first = 1
		for char* key, json_value* member in value.object_values:
			if (first == 0): string_append_char(out, ',')
			first = 0
			json_append_escaped_string(out, key)
			string_append_char(out, ':')
			toml_append_tagged(out, member)
		string_append_char(out, '}')
	else if (value.type == json_type_array()):
		string_append_char(out, '[')
		int i = 0
		while (i < json_array_length(value)):
			if (i > 0): string_append_char(out, ',')
			toml_append_tagged(out, json_array_get(value, i))
			i = i + 1
		string_append_char(out, ']')
	else if (value.type == json_type_string()):
		int kind = value.int_value
		char* type = c"string"
		if (kind == toml_kind_offset_datetime): type = c"datetime"
		else if (kind == toml_kind_local_datetime): type = c"datetime-local"
		else if (kind == toml_kind_local_date): type = c"date-local"
		else if (kind == toml_kind_local_time): type = c"time-local"
		toml_append_leaf(out, type, value.string_value)
	else if (value.type == json_type_int()):
		string_builder* text = string_new()
		string_append_int(text, value.int_value)
		toml_append_leaf(out, c"integer", text.data)
		string_free(text)
	else if (value.type == json_type_float()): toml_append_tagged_float(out, value)
	else if (value.type == json_type_bool()):
		if (value.int_value): toml_append_leaf(out, c"bool", c"true")
		else: toml_append_leaf(out, c"bool", c"false")


# toml-test's tagged JSON for a parsed tree (caller frees): tables are
# objects, arrays are arrays, and every leaf is {"type":T,"value":S}
# with T one of string, integer, float, bool, datetime, datetime-local,
# date-local, time-local.
char* toml_tagged_json(json_value* value):
	string_builder* out = string_new()
	toml_append_tagged(out, value)
	return toml_take_builder(out)
