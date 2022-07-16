import lib.testing
import lib.testing


void test_arithmetic():
	assert_equal(7, 3 + 2 * 2)
	assert_equal(7, 2 * 2 + 3)


void test_raw_asm():
	raw_asm ("\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90")


int func1():
	return 99


int func2(int* f):
	return f()

/*void test_func_pointer_argument():
	int *f = func1
	debugger
	int got = func2(f)
	debugger
	assert_equal(99, got)*/



/*void test_func_argument_direct():
	int got = func2(func1)
	assert_equal(99, got)*/


void test_func_pointer_variable():
	int *f = func1
	int got = f()
	assert_equal(99, got)

