import lib.testing


type size_t = uint
type char_buffer = char*
type binary_op = fn(int, int) -> int


struct p0_pair:
	int a
	int b


struct p0_callback_box:
	binary_op* op


union p0_value:
	int i
	char* s
	p0_pair pair


enum p0_color:
	red
	green = 4
	blue


int p0_add(int a, int b):
	return a + b


int p0_sub(int a, int b):
	return a - b


bool p0_true():
	return true


p0_pair* p0_make_pair():
	return new p0_pair(8, 9)


p0_pair p0_make_pair_value():
	p0_pair p
	p.a = 13
	p.b = 14
	return p


p0_pair p0_forward_pair_value():
	return p0_make_pair_value()


void test_bool_literals_and_coercion():
	bool yes = true
	bool no = false
	bool normalized = 123
	assert_equal(1, yes)
	assert_equal(0, no)
	assert_equal(1, normalized)
	assert_equal(1, !!normalized)
	assert_equal(0, !normalized)


void test_cast_and_aliases():
	size_t n = 42
	char_buffer text = "typed alias"
	const int fixed = 6
	const char* const_text = "constant text"
	int* p = cast(int*, malloc(4))
	*p = cast(int, n)
	assert_equal(42, *p)
	assert_strings_equal("typed alias", text)
	assert_equal(6, fixed)
	assert_strings_equal("constant text", const_text)
	free(p)


void test_precise_direct_call_return_types():
	bool b = p0_true()
	assert_equal(1, b)
	assert_equal(8, p0_make_pair().a)
	assert_equal(9, p0_make_pair().b)


void test_struct_return_by_value():
	assert_equal(13, p0_make_pair_value().a)
	assert_equal(14, p0_make_pair_value().b)
	assert_equal(14, p0_forward_pair_value().b)
	p0_pair p = p0_make_pair_value()
	assert_equal(13, p.a)
	assert_equal(14, p.b)


void test_typed_function_pointer_local():
	binary_op* op = p0_add
	assert_equal(5, op(2, 3))
	op = p0_sub
	assert_equal(7, op(10, 3))


void test_typed_function_pointer_field():
	p0_callback_box box
	box.op = p0_add
	assert_equal(11, box.op(5, 6))


void test_enum_values():
	p0_color c = green
	assert_equal(0, red)
	assert_equal(4, c)
	assert_equal(5, blue)


void test_union_fields_overlap():
	p0_value v
	v.i = 123
	assert_equal(123, v.i)
	v.s = "union text"
	assert_strings_equal("union text", v.s)
	v.pair.a = 21
	v.pair.b = 22
	assert_equal(21, v.pair.a)
	assert_equal(22, v.pair.b)

