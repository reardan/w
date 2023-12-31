import lib.testing


# Basic test cases

void test_1():
	assert_equal(4, 1 + 3)


void test_2():
	assert_equal(4, 1 + 3)


void test_itoa_0():
	assert_equal(strcmp("0", itoa(0)), 0)


void test_strcpy():
	char* str = malloc(1000)
	char* cur = str
	cur = strcpy(cur, "one ")
	cur = strcpy(cur, "two ")
	cur = strcpy(cur, "three ")
	assert_strings_equal("one two three ", str)
	free(str)


void test_strcpy2000():
	char* str = malloc(10000)
	int i = 0
	char* cur = str
	while (i < 2000):
		cur = strcpy(cur, "one ")
		i = i + 1
	assert_strings_equal("one ", str + 1999 * 4)
	free(str)


void test_strncpy():
	char* str = malloc(100)
	strncpy(str, "abcd1234", 4)
	assert_strings_equal("abcd", str)
	free(str)


void test_starts_with():
	assert1(starts_with("hi there", "hi"))
	assert1(starts_with(" 2", " "))


void test_println():
	println("hi there!")


void test_fail():
	#assert1(0)
	assert1(1)
	asserts("test_fail", 1)
	int i


void test_reverse_n():
	char *hey = "hey there"
	reverse_n(hey, 3)
	assert_strings_equal("yeh there", hey)

# reverse_n():
# n > strlen() would have to be checked with O(n)
# unless we explicitly do this before reversing
# right now, we use a fixed n that is assumed to be within bounds
# we could then fix via min(n, strlen(str))


void test_reverse_odd():
	char *me = "reverseme"
	reverse(me)
	assert_strings_equal("emesrever", me)


void test_reverse_even():
	char *me = "even"
	reverse(me)
	assert_strings_equal("neve", me)


void test_large_reverse():
	int length = 1000
	# TODO


void test_atoi():
	assert_equal(0, atoi("0"))
	assert_equal(0, atoi("00"))
	assert_equal(1, atoi("1"))
	assert_equal(1, atoi("01"))
	assert_equal(-1, atoi("-1"))
	assert_equal(-10, atoi("-10"))
	assert_equal(-100, atoi("-100"))
	assert_equal(-1000, atoi("-1000"))
	assert_equal(10, atoi("10"))
	assert_equal(100, atoi("100"))
	assert_equal(1000, atoi("1000"))


void test_intstrlen():
	assert_equal(5, intstrlen(-1000))
	assert_equal(4, intstrlen(-100))
	assert_equal(3, intstrlen(0-99))
	assert_equal(3, intstrlen(-10))
	assert_equal(2, intstrlen(0-9))
	assert_equal(2, intstrlen(0-2))
	assert_equal(2, intstrlen(-1))
	assert_equal(1, intstrlen(0))
	assert_equal(1, intstrlen(1))
	assert_equal(1, intstrlen(2))
	assert_equal(1, intstrlen(9))
	assert_equal(2, intstrlen(10))
	assert_equal(2, intstrlen(11))
	assert_equal(2, intstrlen(99))
	assert_equal(3, intstrlen(100))
	assert_equal(4, intstrlen(1000))
	assert_equal(7, intstrlen(1000000))


void test_ends_with():
	assert1(ends_with("hi there", "there"))
	assert1(ends_with("hi there", "bere") == 0)
	assert1(ends_with("hi", "hi"))
	assert1(ends_with("ahi", "hi"))
	assert1(ends_with("hi", "i"))
	assert1(ends_with("hi", ""))
	assert1(ends_with("/home/w/git/w/w.w", ".w"))


void test_str_replace_path():
	char* import_path = "path.to.subfolder.file"
	int count = str_replace(import_path, '.', '/')
	assert_strings_equal("path/to/subfolder/file", import_path)
	assert_equal(3, count)


void test_str_replace_repeated():
	char* repeated = ".........."
	int count = str_replace(repeated, '.', '*')
	assert_strings_equal("**********", repeated)
	assert_equal(10, count)


void test_str_replace_empty():
	char* empty = ""
	int count = str_replace(empty, '.', '*')
	assert_strings_equal("", empty)
	assert_equal(0, count)


# Hex
void test_hex():
	assert_strings_equal("0x00001337", hex(4919))


void test_from_hex():
	assert_equal(0, from_hex("0"))
	assert_equal(1, from_hex("1"))
	assert_equal(31, from_hex("1f"))
	assert_equal(4919, from_hex("00001337"))
	assert_equal(305420031, from_hex("123456ff"))
	# todo: 0x syntax
	assert_equal(255, from_hex("0xff"))
	# assert_equal(0x1337, from_hex("1337"))


# Net conversions
void test_ip4_from_string(char* ips):
	assert_strings_equal("0x7f000001", hex(ip4_from_string("127.0.0.1")))
	assert_strings_equal("0x00000000", hex(ip4_from_string("0.0.0.0")))
	assert_strings_equal("0x01010101", hex(ip4_from_string("1.1.1.1")))
	assert_strings_equal("0xffffffff", hex(ip4_from_string("255.255.255.255")))


void test_print_registers():
	print_registers()


void test_print_stack():
	print_stack()

