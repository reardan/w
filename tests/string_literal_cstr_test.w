# wbuild: x64 arch=arm64 arch=wasm
# "..." and f"..." literals decay to their NUL-terminated data pointer
# wherever a char* is expected (docs/projects/arrays_slices_strings.md):
# arguments, initializers, assignments, returns, C-style variadic
# tails, ternaries joining two literals, switch cases. c"..." stays
# valid and means the same thing in these positions.
import lib.testing


char* lit_return():
	return "from return"


int lit_len(char* s):
	return strlen(s)


void test_argument():
	assert_equal(5, lit_len("hello"))
	assert_equal(0, strcmp("same", c"same"))
	assert_strings_equal("a\tb", c"a\tb")


void test_initializer_and_assignment():
	char* p = "init"
	assert_equal(4, strlen(p))
	assert_equal('n', p[1])
	p = "assigned"
	assert_equal(0, strcmp(p, c"assigned"))


void test_return():
	assert_strings_equal(c"from return", lit_return())


void test_utf8_and_escapes():
	char* p = "café\n"
	assert_equal(6, strlen(p))


void test_f_string_to_char_pointer():
	int n = 42
	char* p = f"n={n:04}"
	assert_strings_equal(c"n=0042", p)
	assert_equal(9, lit_len(f"{n} and {n}"))


void test_ternary_of_literals():
	int flag = 1
	char* p = flag ? "yes" : "no"
	assert_strings_equal(c"yes", p)
	flag = 0
	p = flag ? "yes" : "no"
	assert_strings_equal(c"no", p)


void test_string_uses_are_unchanged():
	# a literal still is a string where a string (or a type to infer) is
	# expected
	string s = "text"
	assert_equal(4, s.length)
	x := "inferred"
	assert_equal(8, x.length)
	list[char*] words = list[char*]{"a", "bc"}
	assert_equal(2, strlen(words[1]))
