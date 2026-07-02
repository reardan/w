import lib.testing
import structures.string


void test_new_is_empty():
	string* s = string_new()
	assert_equal(0, s.length)
	assert_equal_hex(0, s.data[0])
	string_free(s)


void test_append():
	string* s = string_new()
	string_append(s, "hello")
	string_append(s, ", ")
	string_append(s, "world")
	assert1(string_equals(s, "hello, world"))
	assert_equal(12, s.length)
	string_free(s)


void test_append_char():
	string* s = string_new()
	string_append_char(s, 'h')
	string_append_char(s, 'i')
	assert1(string_equals(s, "hi"))
	string_free(s)


void test_append_int():
	string* s = string_from("n=")
	string_append_int(s, -42)
	assert1(string_equals(s, "n=-42"))
	string_free(s)


void test_growth():
	string* s = string_new_sized(8)
	int i = 0
	while (i < 100):
		string_append(s, "0123456789")
		i = i + 1
	assert_equal(1000, s.length)
	assert_equal(1000, strlen(s.data))
	string_free(s)


void test_clear():
	string* s = string_from("something")
	string_clear(s)
	assert_equal(0, s.length)
	string_append(s, "new")
	assert1(string_equals(s, "new"))
	string_free(s)
