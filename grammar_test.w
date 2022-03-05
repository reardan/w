import testing
import testing


void test_arithmetic():
	assert_equal(7, 3 + 2 * 2)
	assert_equal(7, 2 * 2 + 3)


void test_int_pointer():
	int want = 7777
	int* ip = want
	int got = ip
	assert_equal(want, got)


void test_char_lookup_0():
	char* want = "a"
	# debugger
	int got = want[0]
	# debugger
	assert_equal('a', got)


void test_raw_asm():
	raw_asm ("\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90")


int func1():
	return 99


int func2(int* f):
	return f()


void test_func_pointer_variable():
	int *f = func1
	int got = f()
	assert_equal(99, got)

