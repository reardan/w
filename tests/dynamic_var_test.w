import lib.testing
import lib.utf8
import structures.w_dynamic


# var globals start as a null box pointer (tag 0)
var var_test_global
var var_null_global


void test_int_box_unbox_roundtrip():
	var x = 5
	int n = x
	assert_equal(5, n)
	assert_equal(1, __w_var_tag(x))


void test_rebinding_changes_runtime_type():
	var x = 5
	assert_equal(1, __w_var_tag(x))
	x = c"hello"
	assert_equal(2, __w_var_tag(x))
	char* p = x
	assert_strings_equal(c"hello", p)
	x = s"now a string"
	assert_equal(3, __w_var_tag(x))
	string s = x
	assert_equal(0, strcmp(cstr(s), c"now a string"))
	x = 7
	assert_equal(1, __w_var_tag(x))


void test_arithmetic_on_int_vars():
	var a = 10
	var b = 3
	var sum = a + b
	var diff = a - b
	var prod = a * b
	var quot = a / b
	assert_equal(13, sum)
	assert_equal(7, diff)
	assert_equal(30, prod)
	assert_equal(3, quot)


void test_mixed_var_and_int_arithmetic():
	var a = 10
	var sum = a + 5
	assert_equal(15, sum)
	var sum2 = 5 + a
	assert_equal(15, sum2)
	int n = a
	var sum3 = a * n
	assert_equal(100, sum3)


void test_equality_int():
	var a = 5
	var b = 5
	var c = 6
	assert_equal(1, a == b)
	assert_equal(0, a == c)
	assert_equal(1, a != c)
	assert_equal(1, a == 5)
	assert_equal(1, 5 == a)
	assert_equal(0, a != 5)


void test_equality_strings_compare_content():
	var a = c"hi"
	var b = s"hi"
	var c = c"ho"
	assert_equal(1, a == b)
	assert_equal(0, a == c)
	assert_equal(1, a != c)
	assert_equal(1, a == c"hi")
	assert_equal(1, a == s"hi")
	# different tag families are unequal, not a trap
	var n = 5
	assert_equal(0, a == n)


void test_ordering_ints():
	var a = 3
	var b = 4
	assert_equal(1, a < b)
	assert_equal(0, b < a)
	assert_equal(1, a <= 3)
	assert_equal(1, b >= 4)
	assert_equal(1, b > a)
	assert_equal(0, a > b)
	assert_equal(1, a < 100)
	assert_equal(1, 100 > a)


var var_double(var v):
	return v + v


int var_unbox_add(var a, int b):
	int n = a
	return n + b


var var_pick(int which):
	if (which):
		return 42
	return c"forty-two"


void test_var_as_function_arg_and_return():
	var x = 21
	var d = var_double(x)
	assert_equal(42, d)
	assert_equal(25, var_unbox_add(x, 4))
	assert_equal(1, __w_var_tag(var_pick(1)))
	assert_equal(2, __w_var_tag(var_pick(0)))
	int unboxed = var_pick(1)
	assert_equal(42, unboxed)


void test_aliasing_semantics():
	# var-to-var assignment copies the box pointer; rebinding one name
	# allocates a fresh box, so the alias keeps the old value
	var a = 7
	var b = a
	assert_equal(1, a == b)
	a = 100
	assert_equal(7, b)
	assert_equal(100, a)


void test_string_concatenation():
	var a = c"foo"
	var b = s"bar"
	var cat = a + b
	assert_equal(3, __w_var_tag(cat))
	char* p = cat
	assert_strings_equal(c"foobar", p)
	# mixed concat: char* + string literal boxed from the right side
	var cat2 = a + s"!"
	char* p2 = cat2
	assert_strings_equal(c"foo!", p2)


void test_unbox_into_typed_locals():
	var x = 65
	int n = x
	char ch = x
	bool flag = x
	assert_equal(65, n)
	assert_equal('A', ch)
	assert_equal(1, flag)
	x = c"text"
	char* p = x
	assert_strings_equal(c"text", p)
	string s = x
	assert_equal(4, s.length)
	assert_equal(0, strcmp(cstr(s), c"text"))
	# unboxing a char* var to string and back preserves the content
	x = s"data"
	char* q = x
	assert_strings_equal(c"data", q)


void test_tag_helpers_and_null():
	var x = 1
	assert_equal(1, __w_var_tag(x))
	# a var global starts as a null box pointer: tag 0
	assert_equal(0, __w_var_tag(var_test_global))
	var_test_global = 9
	assert_equal(1, __w_var_tag(var_test_global))
	int n = var_test_global
	assert_equal(9, n)


void test_to_cstr_rendering():
	var x = 12345
	assert_strings_equal(c"12345", __w_var_to_cstr(x))
	x = c"plain"
	assert_strings_equal(c"plain", __w_var_to_cstr(x))
	x = s"boxed"
	assert_strings_equal(c"boxed", __w_var_to_cstr(x))
	assert_strings_equal(c"null", __w_var_to_cstr(var_null_global))


void test_var_in_template_string():
	var x = 5
	var y = c"hello"
	string s = f"x={x} y={y}"
	assert_equal(0, strcmp(cstr(s), c"x=5 y=hello"))
	x = s"str"
	string s2 = f"[{x}]"
	assert_equal(0, strcmp(cstr(s2), c"[str]"))


void test_chained_arithmetic():
	var a = 1
	var b = 2
	var c = 3
	var sum = a + b + c
	assert_equal(6, sum)
	var expr = (a + b) * c - 2
	assert_equal(7, expr)
