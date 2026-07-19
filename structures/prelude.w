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
	int i = 0
	while (i < 6):
		frac = frac * 10.0
		int digit = frac
		s[pos] = digit + '0'
		pos = pos + 1
		frac = frac - digit
		i = i + 1
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


# One line from stdin with the newline stripped, or 0 at end of input.
# The buffer is malloc'd and owned by the caller.
char* input():
	int capacity = 64
	char* buffer = malloc(capacity)
	int length = 0
	int c = getchar(0)
	if (c < 0):
		free(buffer)
		return cast(char*, 0)
	while ((c >= 0) && (c != 10)):
		if (length + 2 > capacity):
			int doubled = capacity << 1
			buffer = realloc(buffer, capacity, doubled)
			capacity = doubled
		buffer[length] = c
		length = length + 1
		c = getchar(0)
	buffer[length] = 0
	return buffer


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
