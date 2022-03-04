import testing
import asm


/*void test_void():
	println("test_void()")


void test_int_pointer_alias():
	int value = 7777
	int* ptr = value
	assert_equal(7777, value)
	assert_equal(7777, ptr)

	ptr = 8888
	assert_equal(8888, value)
	assert_equal(8888, ptr)


void other_option_more_like_c():
	int value = 7777
	int* ptr = &value
	assert_equal(7777, value)
	assert_equal(7777, *ptr)

	*ptr = 8888
	assert_equal(8888, value)
	assert_equal(8888, *ptr)


void test_int_pointer_verbose():
	int want = 7777
	print_int("want = ", want)
	# basically this currently behaves as a reference
	# we could use this, or split it into a separate operator
	# then we would 
	int* ip = want
	print_int("ip = ", ip)
	ip = 8888
	print_int("ip = ", ip)
	print_int("want = ", want)
	int got = ip
	print_int("got = ", got)
	assert_equal(want, got)*/


void setup_tokenizer():
	file = open()
	filename = "stdin"



void test_nop():
	setup_tokenizer()
	char* bin = assemble("nop")
	assert_equal(bin[0], 144)  /* 0x90 */
