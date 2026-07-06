import lib.testing


# Compare an f-string result against the expected bytes. The builder's
# buffer is always null-terminated, so .data works as a C string here.
void check(char* want, string got):
	assert_equal(strlen(want), got.length)
	assert_strings_equal(want, got.data)


void test_plain_chunk_only():
	check(c"hello world", f"hello world")


void test_empty():
	string s = f""
	assert_equal(0, s.length)


void test_int_value():
	int count = 42
	check(c"total: 42 items", f"total: {count} items")


void test_negative_int_value():
	int below = -7
	check(c"t=-7", f"t={below}")


void test_char_pointer_value():
	char* name = c"joe"
	check(c"hi joe!", f"hi {name}!")


void test_string_value():
	string inner = s"wide"
	check(c"[wide]", f"[{inner}]")


void test_string_literal_value():
	check(c"a inline b", f"a {s"inline"} b")


void test_multiple_values():
	int a = 1
	char* b = c"two"
	string c = s"three"
	check(c"1, two, three", f"{a}, {b}, {c}")


void test_operator_expression():
	int a = 20
	int b = 22
	check(c"sum=42 shifted=80", f"sum={a + b} shifted={a << 2}")


int tpl_twice(int n):
	return n * 2


void test_call_expression():
	check(c"answer=42", f"answer={tpl_twice(21)}")


void test_adjacent_expressions():
	int a = 4
	int b = 2
	check(c"42", f"{a}{b}")


void test_leading_and_trailing_expressions():
	int x = 9
	check(c"9 mid 9", f"{x} mid {x}")


void test_escaped_braces():
	int x = 1
	check(c"{x} = 1 {}", f"{{x}} = {x} {{}}")


void test_escapes_in_chunks():
	check(c"line1\x0aline2\x09tab\x0d", f"line1\nline2\ttab\r")
	check(c"hex:\x41 quote:\x22", f"hex:\x41 quote:\"")


void test_unicode_in_chunks():
	# \u00e9 is C3 A9; the raw source bytes pass through unchanged
	check(c"caf\xc3\xa9 caf\xc3\xa9", f"caf\u00e9 café")


void test_char_and_bool_values():
	# char and bool interpolate as their numeric value
	char letter = 'A'
	bool flag = true
	check(c"65/1", f"{letter}/{flag}")


enum tpl_color:
	tpl_red
	tpl_green


void test_enum_value():
	tpl_color c = tpl_green
	check(c"color 1", f"color {c}")


int tpl_string_length(string s):
	return s.length


void test_as_function_argument():
	int n = 5
	assert_equal(6, tpl_string_length(f"n is {n}"))


void test_nested_template_string():
	int x = 3
	check(c"outer inner 3", f"outer {f"inner {x}"}")


void test_assignment_and_reuse():
	int total = 10
	string first = f"count {total}"
	string second = f"again: {first}"
	check(c"count 10", first)
	check(c"again: count 10", second)


void test_map_index_expression():
	map[char*, int] m = new map[char*, int]
	m[c"k"] = 12
	check(c"k=12", f"k={m[c"k"]}")
