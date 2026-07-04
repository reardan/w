import lib.testing

c_import "libc.so.6" "tests/c_import_fixture.h"
c_import "libc.so.6" "/usr/include/x86_64-linux-gnu/bits/types/FILE.h"
c_import "libc.so.6" "tests/c_import_libc_fixture.h"


void test_c_import_typedef():
	size_t value = 42
	assert_equal(42, value)


void test_c_import_system_file_typedef():
	FILE* file = 0
	assert_equal(0, file)


void test_c_import_libc_style_typedefs():
	ci_size_t count = 11
	ci_stream stream
	stream.fd = 3
	stream.count = count
	assert_equal(3, stream.fd)
	assert_equal(11, stream.count)


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
