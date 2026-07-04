import lib.testing

c_import "libc.so.6" c"tests/c_import_fixture.h"
c_import "libc.so.6" c"/usr/include/x86_64-linux-gnu/bits/types/FILE.h"
c_import "libc.so.6" c"tests/c_import_libc_fixture.h"
c_import "libc.so.6" c"tests/c_import_macro_fixture.h"
c_import "libc.so.6" c"tests/c_import_eval_fixture.h"


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
	assert1(puts(c"c_import puts OK") >= 0)


void test_c_import_macro_constants():
	assert_equal(77, CI_HEADER_CONSTANT)
	assert_equal(82, CI_HEADER_OFFSET)
	assert_equal(77, CI_HEADER_PASTED)
	ci_macro_int value = CI_HEADER_OFFSET
	assert_equal(82, value)
	ci_if_type gated = 3
	assert_equal(3, gated)


void test_c_import_enum_expressions():
	assert_equal(0 - 3, CI_NEG)
	assert_equal(0 - 2, CI_NEXT)
	assert_equal(16, CI_SHIFTED)
	assert_equal(14, CI_MIXED)
	assert_equal(7, CI_TERNARY)
	assert_equal(17, CI_REF)
	assert_equal(95, CI_HEX_MASK)
	assert_equal(4, CI_SIZEOF_INT)
	assert_equal(4, CI_SIZEOF_PTR)
	assert_equal(2, CI_CAST)


void test_c_import_padded_struct_fields():
	ci_eval_sizes_t s
	s.tag = 'x'
	s.value = 77
	s.tail = 9
	assert_equal('x', s.tag)
	assert_equal(77, s.value)
	assert_equal(9, s.tail)


void test_c_import_function_pointer_typedef():
	ci_eval_callback callback = 0
	assert_equal(0, callback)
