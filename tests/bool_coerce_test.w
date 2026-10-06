# wbuild: x64
# Converting a non-constant int to bool (#525). coerce() used to promote
# the already-loaded value a second time, dereferencing the int as an
# address. Every position that coerces to bool is covered: declaration,
# assignment, call argument, return value and struct field store, each
# with 0, 1, negative, large and low-byte-zero values.
import lib.testing


struct flags:
	int before
	bool flag
	int after


int as_int(bool b):
	return b


bool to_bool(int n):
	return n


int stored_byte(bool* p):
	char* bytes = cast(char*, p)
	return bytes[0]


int via_declaration(int n):
	bool b = n
	assert_equal(as_int(b), stored_byte(&b))
	return b


int via_assignment(int n):
	bool b = 0
	b = n
	assert_equal(as_int(b), stored_byte(&b))
	return b


int via_argument(int n):
	return as_int(n)


int via_return(int n):
	bool b = to_bool(n)
	return b


int via_field(int n):
	flags f
	f.before = 0x1234567
	f.after = 0x7654321
	f.flag = n
	assert_equal_hex(0x1234567, f.before)
	assert_equal_hex(0x7654321, f.after)
	assert_equal(as_int(f.flag), stored_byte(&f.flag))
	return f.flag


int via_heap_field(int n):
	flags* f = new flags()
	f.flag = n
	return f.flag


void check(int n, int want):
	assert_equal(want, via_declaration(n))
	assert_equal(want, via_assignment(n))
	assert_equal(want, via_argument(n))
	assert_equal(want, via_return(n))
	assert_equal(want, via_field(n))
	assert_equal(want, via_heap_field(n))


void test_bool_coerce_values():
	check(0, 0)
	check(1, 1)
	check(-1, 1)
	check(-123456, 1)
	check(256, 1)
	check(0x40000000, 1)
	check(0x7fffffff, 1)
	int min = 1 << (sizeof(int) * 8 - 1)
	check(min, 1)


void test_bool_coerce_word_high_bits():
	# On x64 a value whose low 32 bits are zero is still nonzero.
	int high = 1 << (sizeof(int) * 8 - 2)
	check(high, 1)


void test_bool_coerce_char_source():
	char c = 0
	bool b = c
	assert_equal(0, as_int(b))
	c = 200
	b = c
	assert_equal(1, as_int(b))
