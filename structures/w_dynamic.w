/*
Runtime for the dynamic 'var' type.

The compiler lowers var conversions and operators (grammar/var_builtin.w)
to these helpers. A var value is a pointer to a heap-allocated tagged
box; tags: 0 null, 1 int (covers char/bool/enum), 2 char*, 3 string
(payload = data pointer, payload2 = length). A null box POINTER also
reads as the null tag so zero-initialized var globals are well behaved.

Boxes are never freed (v1, matches the compiler's arena style). Boxed
char* and string data is shared with the source, not cloned; conversions
that need new bytes (__w_var_to_cstr, concatenation, string-to-cstr
unboxing) allocate fresh buffers.

Unbox and operator tag mismatches trap: print a message to stderr and
exit(1) (same style as cstr_invalid_utf8 in lib/lib.w).

Like the other __w_ runtimes, this module is imported on demand: the
compiler resolves the helpers by name, either directly when the program
imports structures.w_dynamic itself or through backpatch chains filled
in by the deferred import at the end of compilation (var_finish_import).

Design notes: docs/projects/dynamic_var.md.
*/
import lib.lib


struct __w_var_box:
	int tag
	int payload
	int payload2


int __w_var_tag_of(__w_var_box* b):
	if (cast(int, b) == 0):
		return 0
	return b.tag


# Runtime tag of a var value (0 null, 1 int, 2 char*, 3 string). Takes
# void* so seed-safe code and tests can pass a var directly (var
# converts to void* by exposing the raw box pointer).
int __w_var_tag(void* v):
	return __w_var_tag_of(cast(__w_var_box*, cast(int, v)))


char* __w_var_tag_name(int tag):
	if (tag == 1):
		return c"int"
	if (tag == 2):
		return c"char*"
	if (tag == 3):
		return c"string"
	return c"null"


void __w_var_stderr(char* message):
	write(2, message, strlen(message))


void __w_var_type_error(char* expected, int got_tag):
	__w_var_stderr(c"var runtime error: expected ")
	__w_var_stderr(expected)
	__w_var_stderr(c", got ")
	__w_var_stderr(__w_var_tag_name(got_tag))
	__w_var_stderr(c"\x0a")
	exit(1)


void __w_var_binary_error(char* op, __w_var_box* a, __w_var_box* b):
	__w_var_stderr(c"var runtime error: unsupported operand types for ")
	__w_var_stderr(op)
	__w_var_stderr(c": ")
	__w_var_stderr(__w_var_tag_name(__w_var_tag_of(a)))
	__w_var_stderr(c" and ")
	__w_var_stderr(__w_var_tag_name(__w_var_tag_of(b)))
	__w_var_stderr(c"\x0a")
	exit(1)


__w_var_box* __w_var_alloc(int tag, int payload, int payload2):
	__w_var_box* b = malloc(3 * __word_size__)
	b.tag = tag
	b.payload = payload
	b.payload2 = payload2
	return b


__w_var_box* __w_var_box_int(int v):
	return __w_var_alloc(1, v, 0)


__w_var_box* __w_var_box_cstr(char* p):
	return __w_var_alloc(2, cast(int, p), 0)


__w_var_box* __w_var_box_str(string s):
	return __w_var_alloc(3, cast(int, s.data), s.length)


int __w_var_unbox_int(__w_var_box* b):
	if (__w_var_tag_of(b) != 1):
		__w_var_type_error(c"int", __w_var_tag_of(b))
	return b.payload


void __w_var_copy_bytes(char* dst, char* src, int count):
	int i = 0
	while (i < count):
		dst[i] = src[i]
		i = i + 1


# NUL-terminated copy of length bytes at data.
char* __w_var_cstr_from_data(int data, int length):
	char* out = malloc(length + 1)
	__w_var_copy_bytes(out, cast(char*, data), length)
	out[length] = 0
	return out


# Unbox to char*: tag 2 returns the stored pointer; tag 3 returns a
# fresh NUL-terminated copy of the string's bytes.
char* __w_var_unbox_cstr(__w_var_box* b):
	int tag = __w_var_tag_of(b)
	if (tag == 2):
		return cast(char*, b.payload)
	if (tag == 3):
		return __w_var_cstr_from_data(b.payload, b.payload2)
	__w_var_type_error(c"char*", tag)
	return 0


# Unbox to string: tag 3 rebuilds a {data, length} descriptor sharing
# the stored bytes; tag 2 measures the C string.
string __w_var_unbox_str(__w_var_box* b):
	int tag = __w_var_tag_of(b)
	if (tag == 2):
		return str_from_cstr(cast(char*, b.payload))
	if (tag != 3):
		__w_var_type_error(c"string", tag)
	char* descriptor = malloc(2 * __word_size__)
	save_word(descriptor, b.payload)
	save_word(descriptor + __word_size__, b.payload2)
	return cast(string, cast(int, descriptor))


# 1 when the box holds text (char* or string)
int __w_var_is_text(__w_var_box* b):
	int tag = __w_var_tag_of(b)
	return (tag == 2) | (tag == 3)


int __w_var_text_length(__w_var_box* b):
	if (b.tag == 2):
		return strlen(cast(char*, b.payload))
	return b.payload2


__w_var_box* __w_var_concat(__w_var_box* a, __w_var_box* b):
	int a_length = __w_var_text_length(a)
	int b_length = __w_var_text_length(b)
	char* out = malloc(a_length + b_length + 1)
	__w_var_copy_bytes(out, cast(char*, a.payload), a_length)
	__w_var_copy_bytes(out + a_length, cast(char*, b.payload), b_length)
	out[a_length + b_length] = 0
	return __w_var_alloc(3, cast(int, out), a_length + b_length)


# '+': int addition, or concatenation when both operands are text
__w_var_box* __w_var_add(__w_var_box* a, __w_var_box* b):
	if (__w_var_is_text(a) & __w_var_is_text(b)):
		return __w_var_concat(a, b)
	if ((__w_var_tag_of(a) == 1) & (__w_var_tag_of(b) == 1)):
		return __w_var_alloc(1, a.payload + b.payload, 0)
	__w_var_binary_error(c"+", a, b)
	return 0


__w_var_box* __w_var_sub(__w_var_box* a, __w_var_box* b):
	if ((__w_var_tag_of(a) == 1) & (__w_var_tag_of(b) == 1)):
		return __w_var_alloc(1, a.payload - b.payload, 0)
	__w_var_binary_error(c"-", a, b)
	return 0


__w_var_box* __w_var_mul(__w_var_box* a, __w_var_box* b):
	if ((__w_var_tag_of(a) == 1) & (__w_var_tag_of(b) == 1)):
		return __w_var_alloc(1, a.payload * b.payload, 0)
	__w_var_binary_error(c"*", a, b)
	return 0


__w_var_box* __w_var_div(__w_var_box* a, __w_var_box* b):
	if ((__w_var_tag_of(a) == 1) & (__w_var_tag_of(b) == 1)):
		return __w_var_alloc(1, a.payload / b.payload, 0)
	__w_var_binary_error(c"/", a, b)
	return 0


# ==/!=: same-tag compare; ints by value, text by content (char* and
# string tags compare with each other), null equals only null.
# Mismatched tag families are unequal, not a trap.
int __w_var_eq(__w_var_box* a, __w_var_box* b):
	int a_tag = __w_var_tag_of(a)
	int b_tag = __w_var_tag_of(b)
	if ((a_tag == 0) && (b_tag == 0)):
		return 1
	if ((a_tag == 1) && (b_tag == 1)):
		return a.payload == b.payload
	if (__w_var_is_text(a) & __w_var_is_text(b)):
		int a_length = __w_var_text_length(a)
		int b_length = __w_var_text_length(b)
		if (a_length != b_length):
			return 0
		char* a_data = cast(char*, a.payload)
		char* b_data = cast(char*, b.payload)
		int i = 0
		while (i < a_length):
			if (a_data[i] != b_data[i]):
				return 0
			i = i + 1
		return 1
	return 0


# Ordering: ints only, -1/0/1; anything else traps
int __w_var_cmp(__w_var_box* a, __w_var_box* b):
	if ((__w_var_tag_of(a) == 1) & (__w_var_tag_of(b) == 1)):
		if (a.payload < b.payload):
			return -1
		if (a.payload > b.payload):
			return 1
		return 0
	__w_var_binary_error(c"ordering", a, b)
	return 0


# Readable rendering as a fresh (or shared, for tag 2) C string; used
# by print_var and f"..." template string interpolation. Takes void*
# like __w_var_tag so tests can pass a var directly.
char* __w_var_to_cstr(void* v):
	__w_var_box* b = cast(__w_var_box*, cast(int, v))
	int tag = __w_var_tag_of(b)
	if (tag == 1):
		return itoa(b.payload)
	if (tag == 2):
		return cast(char*, b.payload)
	if (tag == 3):
		return __w_var_cstr_from_data(b.payload, b.payload2)
	return c"null"


# Print a readable rendering of a var and a newline to stdout. Takes
# void* (the raw box pointer) so this seed-safe module can accept a var.
void print_var(void* v):
	char* text = __w_var_to_cstr(v)
	write(1, text, strlen(text))
	write(1, c"\x0a", 1)
