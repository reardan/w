# wbuild: x64
# wbuild: step="bin/string_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import structures.string


void test_new_is_empty():
	string_builder* s = string_new()
	assert_equal(0, s.length)
	assert_equal_hex(0, s.data[0])
	string_free(s)


void test_append():
	string_builder* s = string_new()
	string_append(s, c"hello")
	string_append(s, c", ")
	string_append(s, c"world")
	assert1(string_equals(s, c"hello, world"))
	assert_equal(12, s.length)
	string_free(s)


void test_append_char():
	string_builder* s = string_new()
	string_append_char(s, 'h')
	string_append_char(s, 'i')
	assert1(string_equals(s, c"hi"))
	string_free(s)


void test_append_int():
	string_builder* s = string_from(c"n=")
	string_append_int(s, -42)
	assert1(string_equals(s, c"n=-42"))
	string_free(s)


# Two digits per division (pair table): every digit count, both signs
# and the word's extremes.
void append_int_case(int v, char* want):
	string_builder* s = string_new()
	string_append_int(s, v)
	assert_strings_equal(want, s.data)
	assert_equal(strlen(want), s.length)
	string_free(s)


void test_append_int_digits():
	append_int_case(0, c"0")
	append_int_case(9, c"9")
	append_int_case(-9, c"-9")
	append_int_case(10, c"10")
	append_int_case(-10, c"-10")
	append_int_case(99, c"99")
	append_int_case(100, c"100")
	append_int_case(-100, c"-100")
	append_int_case(1000001, c"1000001")
	append_int_case(2147483647, c"2147483647")
	append_int_case(0 - 2147483647 - 1, c"-2147483648")
	if (__word_size__ == 8):
		int top = ((2147483647 << 16) << 16) | (((65535 << 16) | 65535) & ((1 << 32) - 1))
		append_int_case(top, c"9223372036854775807")
		append_int_case(0 - top - 1, c"-9223372036854775808")
	for i in range(-2000, 2000):
		char* want = itoa(i * 997)
		append_int_case(i * 997, want)
		free(want)


void test_growth():
	string_builder* s = string_new_sized(8)
	for i in range(100): string_append(s, c"0123456789")
	assert_equal(1000, s.length)
	assert_equal(1000, strlen(s.data))
	string_free(s)


void test_clear():
	string_builder* s = string_from(c"something")
	string_clear(s)
	assert_equal(0, s.length)
	string_append(s, c"new")
	assert1(string_equals(s, c"new"))
	string_free(s)
