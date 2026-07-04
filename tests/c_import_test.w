import lib.testing

c_import "libc.so.6" "tests/c_import_fixture.h"


void test_c_import_typedef():
	size_t value = 42
	assert_equal(42, value)


void test_c_import_struct_fields():
	point p
	p.x = 7
	p.y = 9
	assert_equal(7, p.x)
	assert_equal(9, p.y)


void test_c_import_enum_values():
	assert_equal(0, red)
	assert_equal(4, green)
	assert_equal(5, blue)


void test_c_import_extern_function():
	assert1(puts("c_import puts OK") >= 0)
