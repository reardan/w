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
	if (capacity < 8):
		capacity = 8
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
		if (new_capacity < needed):
			new_capacity = needed
		s.data = realloc(s.data, s.length + 1, new_capacity)
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


void string_clear(string_builder* s):
	s.length = 0
	s.data[0] = 0


void string_free(string_builder* s):
	free(s.data)
	free(s)
