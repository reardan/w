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
	int i = 0
	while (i < length):
		s.data[s.length + i] = data[i]
		i = i + 1
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


void string_clear(string_builder* s):
	s.length = 0
	s.data[0] = 0


void string_free(string_builder* s):
	free(s.data)
	free(s)
