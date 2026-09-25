# wbuild: x64 arch=arm64 arch=wasm
# wbuild: step="bin/wv2 tests/switch_pointer_error_fixture.w -o bin/switch_pointer_error_fixture" expect_fail expect_stderr="switch expression must be an int-like value, a string or a char*, got 'int*'"
# String ergonomics: == / != on two string operands compare contents
# (grammar/equality_expr.w), and switch on a string or a char*
# compares case values by contents (grammar/switch_statement.w).
# char* == char* stays a pointer comparison.
import lib.testing


string str_of(char* p):
	return str_from_cstr(p)


void test_string_equality_compares_contents():
	string a = str_of(c"hello")
	string b = str_of(c"hello")
	string c = str_of(c"help!")
	assert1(a == b)
	assert_equal(0, a != b)
	assert_equal(0, a == c)
	assert1(a != c)
	assert1(a == "hello")
	assert1("hello" == b)
	assert1("x" != "y")


void test_f_string_equality():
	int n = 7
	assert1(f"n={n}" == "n=7")
	assert1(f"{n}{n}" != "7")


void test_prefix_and_length_mismatch():
	string a = str_of(c"abc")
	assert_equal(0, a == "ab")
	assert_equal(0, a == "abcd")
	assert1(str_of(c"") == "")


void test_null_descriptors():
	string none = cast(string, 0)
	string other = cast(string, 0)
	string empty = str_of(c"")
	assert1(none == other)
	assert_equal(0, none == empty)
	assert1(none != "")
	# a string against the constant 0 stays a null check
	assert1(none == 0)
	assert_equal(0, empty == 0)


void test_char_pointer_equality_is_identity():
	char* a = strclone(c"same")
	char* b = strclone(c"same")
	assert_equal(0, a == b)
	assert1(a == a)


int classify_string(string s):
	switch s:
		case "red": return 1
		case "green", "blue": return 2
		case "": return 3
		default: return 0


int classify_cstr(char* p):
	switch p:
		case 0: return -1
		case "red": return 1
		case c"green", "blue": return 2
		default: return 0


void test_switch_on_string():
	assert_equal(1, classify_string(str_of(c"red")))
	assert_equal(2, classify_string(str_of(c"blue")))
	assert_equal(2, classify_string(str_of(c"green")))
	assert_equal(3, classify_string(str_of(c"")))
	assert_equal(0, classify_string(str_of(c"reds")))
	int n = 1
	assert_equal(0, classify_string(f"red{n}"))


void test_switch_on_char_pointer():
	assert_equal(1, classify_cstr(strclone(c"red")))
	assert_equal(2, classify_cstr(strclone(c"green")))
	assert_equal(2, classify_cstr(strclone(c"blue")))
	assert_equal(0, classify_cstr(strclone(c"purple")))
	assert_equal(-1, classify_cstr(0))
