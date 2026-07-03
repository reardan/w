import lib.lib
import lib.assert


struct wide_box:
	int64 signed_value
	uint64 unsigned_value


int64 make_signed_wide():
	int64 one = 1
	return one << 40


uint64 make_unsigned_wide():
	uint64 one = 1
	return one << 36


int64 add_wide(int64 a, int64 b):
	return a + b


void test_int64_arithmetic_and_returns():
	int64 big = make_signed_wide()
	assert_equal(1, big >> 40)
	assert_equal(3, add_wide(big, big + big) >> 40)
	assert1(big > 0)


void test_uint64_storage_and_fields():
	wide_box box
	box.signed_value = make_signed_wide()
	box.unsigned_value = make_unsigned_wide()
	assert_equal(1, box.signed_value >> 40)
	assert_equal(1, box.unsigned_value >> 36)


int main():
	test_int64_arithmetic_and_returns()
	test_uint64_storage_and_fields()
	println("x64 int64 OK")
	return 0
