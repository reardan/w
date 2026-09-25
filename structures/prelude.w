/*
Runtime for the built-in polymorphic print/println and the golf-oriented
input helpers (docs/projects/golf_ergonomics.md).

The compiler lowers print(x)/println(x) to the __w_print_* helpers here,
dispatching on the argument's static type (grammar/print_builtin.w). The
module is imported on demand at a top-level boundary, exactly like the
f-string runtime (structures/string.w): programs that never print and
never call input()/read_all()/ints() do not pay for it.

Like the other __w_ runtimes this file must stay compatible with the
oldest compiler that may compile it: plain W only.
*/
import lib.lib
import structures.w_list


void __w_print_nl():
	put_char(10)


void __w_print_cstr(char* s):
	write(1, s, strlen(s))


# A char-typed print argument renders as the character itself, one byte
# (grammar/print_builtin.w routes only genuine char values here).
void __w_print_char(int c):
	put_char(c)


void __w_print_int(int value):
	char* s = itoa(value)
	write(1, s, strlen(s))


void __w_print_str(string s):
	write_string(1, s)


# Same fixed six-fraction-digit rendering as lib/format.w's ftoa, kept
# private here so the prelude never collides with programs that
# c_import libc's printf (lib/format.w defines a W printf).
void __w_print_float32(float f):
	char* s = malloc(64)
	int pos = 0
	if (f < 0.0):
		s[pos] = '-'
		pos = pos + 1
		f = -f
	int whole = f
	char* whole_digits = itoa(whole)
	strcpy(s + pos, whole_digits)
	free(whole_digits)
	pos = strlen(s)
	s[pos] = '.'
	pos = pos + 1
	float frac = f - whole
	for i in range(6):
		frac = frac * 10.0
		int digit = frac
		s[pos] = digit + '0'
		pos = pos + 1
		frac = frac - digit
	s[pos] = 0
	write(1, s, pos)
	free(s)


# '[a, b, c]' for scalar element lists; kind selects the element
# formatter: 2 char*, 3 int-like, 4 string (same codes as the f-string
# helper table).
void __w_print_list(__w_list* list, int kind):
	__w_print_cstr(c"[")
	int i = 0
	while (i < list.length):
		if (i > 0):
			__w_print_cstr(c", ")
		int value = __w_list_load_word(list.items + i * list.element_size, list.element_size)
		if (kind == 2):
			__w_print_cstr(cast(char*, value))
		else if (kind == 4):
			write_string(1, cast(string, value))
		else:
			__w_print_int(value)
		i = i + 1
	__w_print_cstr(c"]")


# Prelude math (issue #360): max/min/abs reachable without an import.
# The compiler resolves bare max(a, b)/min(a, b)/abs(a) call sites to
# these helpers only when no user symbol shadows the name
# (grammar/print_builtin.w); lib/math.w keeps its own min/max/abs for
# programs that import it, which then win the lookup.
int __w_max(int a, int b):
	if (a > b):
		return a
	return b


int __w_min(int a, int b):
	if (a < b):
		return a
	return b


int __w_abs(int a):
	if (a < 0):
		return 0 - a
	return a


# Prelude any/all (issue #360): truthiness scans over a list[T] of
# int-like elements, reachable without an import. The compiler
# validates the argument type at compile time
# (grammar/print_builtin.w); the empty-list results follow the Python
# contract (any([]) is false, all([]) is true).
int __w_any(__w_list* list):
	int i = 0
	while (i < list.length):
		if (__w_list_load_word(list.items + i * list.element_size, list.element_size)):
			return 1
		i = i + 1
	return 0


int __w_all(__w_list* list):
	int i = 0
	while (i < list.length):
		if (__w_list_load_word(list.items + i * list.element_size, list.element_size) == 0):
			return 0
		i = i + 1
	return 1


# One line from stdin with the newline stripped, as a UTF-8 string
# (issue #360), or 0 at end of input — a null descriptor, false in a
# condition. The buffer and descriptor are malloc'd and owned by the
# caller; cstr()/cstr_clone() (lib/utf8.w) recover a C string.
string input():
	int capacity = 64
	char* buffer = malloc(capacity)
	int length = 0
	int c = getchar(0)
	if (c < 0):
		free(buffer)
		return cast(string, 0)
	while ((c >= 0) && (c != 10)):
		if (length + 2 > capacity):
			int doubled = capacity << 1
			buffer = realloc(buffer, capacity, doubled)
			capacity = doubled
		buffer[length] = c
		length = length + 1
		c = getchar(0)
	buffer[length] = 0
	return str_from_cstr(buffer)


# All of stdin as one malloc'd C string.
char* read_all():
	int capacity = 256
	char* buffer = malloc(capacity)
	int length = 0
	int c = getchar(0)
	while (c >= 0):
		if (length + 2 > capacity):
			int doubled = capacity << 1
			buffer = realloc(buffer, capacity, doubled)
			capacity = doubled
		buffer[length] = c
		length = length + 1
		c = getchar(0)
	buffer[length] = 0
	return buffer


# Every integer in stdin, in order, sign included ('x=-3, y=7' yields
# -3 and 7): the one-liner for numeric puzzle input.
list[int] ints():
	list[int] values = new list[int]
	char* text = read_all()
	int i = 0
	while (text[i] != 0):
		int is_digit = (text[i] >= '0') & (text[i] <= '9')
		int is_negative = 0
		if (text[i] == '-'):
			if ((text[i + 1] >= '0') && (text[i + 1] <= '9')):
				is_negative = 1
				i = i + 1
				is_digit = 1
		if (is_digit):
			int value = 0
			while ((text[i] >= '0') && (text[i] <= '9')):
				value = value * 10 + (text[i] - '0')
				i = i + 1
			if (is_negative):
				value = 0 - value
			values.push(value)
		else:
			i = i + 1
	free(text)
	return values


# ---- Script helpers (golf ergonomics wave 5) ----
# lines(), words(), split(s[, ch]) and join(l, sep) are reachable
# without an import: the compiler resolves the bare names to these
# private __w_ helpers only when no user symbol shadows them
# (grammar/print_builtin.w), so programs that define or import their
# own lines()/split()/join() (lib/str.w) never collide with the prelude.

# Bytes [start, end) as a new C string.
char* __w_piece(char* s, int start, int end):
	char* piece = malloc(end - start + 1)
	int i = 0
	while (start + i < end):
		piece[i] = s[start + i]
		i = i + 1
	piece[i] = 0
	return piece


# Pieces of s[0, length): delimiter 0 splits on runs of ASCII
# whitespace and drops empty pieces (Python's s.split()); any other
# byte splits on every occurrence and keeps empty pieces (lib/str.w's
# split(s, ch) contract).
list[char*] __w_split_bytes(char* s, int length, int delimiter):
	list[char*] pieces = new list[char*]
	int start = 0
	for i in range(length + 1):
		int is_break = i == length
		if ((is_break == 0) && (delimiter == 0)):
			is_break = (s[i] == ' ') || ((s[i] >= 9) && (s[i] <= 13))
		else if (is_break == 0):
			is_break = s[i] == delimiter
		if (is_break):
			if ((delimiter != 0) || (i > start)):
				pieces.push(__w_piece(s, start, i))
			start = i + 1
	return pieces


# split(s) / split(s, ch) for a char* (is_string 0) or string argument.
list[char*] __w_split(int s, int is_string, int delimiter):
	if (is_string):
		string text = cast(string, s)
		return __w_split_bytes(text.data, text.length, delimiter)
	char* chars = cast(char*, s)
	return __w_split_bytes(chars, strlen(chars), delimiter)


# Every stdin line without its newline; a final newline does not add an
# empty last line.
list[char*] __w_lines():
	char* text = read_all()
	list[char*] pieces = __w_split_bytes(text, strlen(text), 10)
	if (strlen(pieces[pieces.length - 1]) == 0):
		pieces.pop()
	free(text)
	return pieces


# Every whitespace-separated token of stdin.
list[char*] __w_words():
	char* text = read_all()
	list[char*] pieces = __w_split_bytes(text, strlen(text), 0)
	free(text)
	return pieces


# Copies length bytes to result + out and returns the new end; a null
# result only measures.
int __w_join_copy(char* result, int out, char* data, int length):
	if (cast(int, result) != 0):
		for j in range(length):
			result[out + j] = data[j]
	return out + length


# The pieces joined with sep between them, as a new C string: one
# measuring round, one copying. flags bit 0: the pieces are strings
# (else char*); bit 1: sep is a string (else char*).
char* __w_join(__w_list* parts, int sep, int flags):
	char* sep_data = cast(char*, sep)
	int sep_length = 0
	if (flags & 2):
		string sep_text = cast(string, sep)
		sep_data = sep_text.data
		sep_length = sep_text.length
	else:
		sep_length = strlen(sep_data)
	char* result = 0
	for round in range(2):
		int out = 0
		int i = 0
		while (i < parts.length):
			if (i > 0):
				out = __w_join_copy(result, out, sep_data, sep_length)
			int word = __w_list_load_word(parts.items + i * parts.element_size, parts.element_size)
			if (flags & 1):
				string text = cast(string, word)
				out = __w_join_copy(result, out, text.data, text.length)
			else:
				out = __w_join_copy(result, out, cast(char*, word), strlen(cast(char*, word)))
			i = i + 1
		if (round == 0):
			result = malloc(out + 1)
		else:
			result[out] = 0
	return result

# --- enum_name ------------------------------------------------------------
# enum_name(e) (grammar/print_builtin.w): table is the compiler-emitted
# run of NUL-terminated "value" / "name" pairs for e's enum, ended by an
# empty value. Returns the name inside the table, or the value's decimal
# digits when no constant carries it.
char* __w_enum_name(char* table, int value):
	char* p = table
	while (p[0] != 0):
		int negative = p[0] == '-'
		int i = negative
		int v = 0
		while (p[i] != 0):
			v = v * 10 + p[i] - '0'
			i = i + 1
		if (negative):
			v = 0 - v
		p = p + i + 1
		if (v == value):
			return p
		p = p + strlen(p) + 1
	return itoa(value)
