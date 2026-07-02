/*
Growable string builder.

The data buffer is always null-terminated, so it can be passed to any
function expecting a C string at any time.
*/
import lib.lib
import lib.assert


struct string:
	int capacity
	int length
	char* data


string* string_new_sized(int capacity):
	if (capacity < 8):
		capacity = 8
	string* s = malloc(12)
	s.capacity = capacity
	s.length = 0
	s.data = malloc(capacity)
	s.data[0] = 0
	return s


string* string_new():
	return string_new_sized(16)


# Make sure extra more bytes (plus the terminator) fit.
void string_reserve(string* s, int extra):
	int needed = s.length + extra + 1
	if (needed > s.capacity):
		int new_capacity = s.capacity * 2
		if (new_capacity < needed):
			new_capacity = needed
		s.data = realloc(s.data, s.length + 1, new_capacity)
		s.capacity = new_capacity


void string_append(string* s, char* c):
	int n = strlen(c)
	string_reserve(s, n)
	strcpy(s.data + s.length, c)
	s.length = s.length + n
	s.data[s.length] = 0


void string_append_char(string* s, int c):
	string_reserve(s, 1)
	s.data[s.length] = c
	s.length = s.length + 1
	s.data[s.length] = 0


string* string_from(char* c):
	string* s = string_new_sized(strlen(c) + 1)
	string_append(s, c)
	return s


void string_append_int(string* s, int v):
	char* digits = itoa(v)
	string_append(s, digits)
	free(digits)


int string_equals(string* s, char* c):
	return strcmp(s.data, c) == 0


void string_clear(string* s):
	s.length = 0
	s.data[0] = 0


void string_free(string* s):
	free(s.data)
	free(s)
