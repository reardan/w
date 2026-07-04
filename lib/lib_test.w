import lib.testing


# Basic test cases

void test_1():
	assert_equal(4, 1 + 3)


void test_2():
	assert_equal(4, 1 + 3)


void test_itoa_0():
	assert_equal(strcmp(c"0", itoa(0)), 0)


void test_strcpy():
	char* str = malloc(1000)
	char* cur = str
	cur = strcpy(cur, c"one ")
	cur = strcpy(cur, c"two ")
	cur = strcpy(cur, c"three ")
	assert_strings_equal(c"one two three ", str)
	free(str)


void test_strcpy2000():
	char* str = malloc(10000)
	int i = 0
	char* cur = str
	while (i < 2000):
		cur = strcpy(cur, c"one ")
		i = i + 1
	assert_strings_equal(c"one ", str + 1999 * 4)
	free(str)


void test_strncpy():
	char* str = malloc(100)
	strncpy(str, c"abcd1234", 4)
	# strncpy copies at most n chars and does not null-terminate
	str[4] = 0
	assert_strings_equal(c"abcd", str)
	free(str)


void test_malloc_free_reuse():
	char* a = malloc(100)
	strcpy(a, c"hello")
	free(a)
	# The freed block should be recycled for an equal-sized request
	char* b = malloc(100)
	assert_equal(a, b)
	free(b)


void test_malloc_reuse_loop():
	# A steady alloc/free cycle must not leak: the same block comes back
	int first = malloc(1000)
	free(first)
	int i = 0
	while (i < 1000):
		int p = malloc(1000)
		assert_equal(first, p)
		free(p)
		i = i + 1


void test_malloc_split():
	char* big = malloc(256)
	free(big)
	# A smaller request splits the free block instead of growing the heap
	char* head = malloc(64)
	assert_equal(big, head)
	char* rest = malloc(64)
	assert_equal(big + 72, rest)
	free(head)
	free(rest)


void test_malloc_zero_and_alignment():
	int a = malloc(0)
	int b = malloc(1)
	assert1(a != 0)
	assert1(b != 0)
	assert1(a != b)
	# Payloads are 8-byte aligned
	assert_equal(0, a & 7)
	assert_equal(0, b & 7)
	free(a)
	free(b)


void test_starts_with():
	assert1(starts_with(c"hi there", c"hi"))
	assert1(starts_with(c" 2", c" "))


void test_println():
	println(c"hi there!")


void test_fail():
	#assert1(0)
	assert1(1)
	asserts(c"test_fail", 1)
	int i


void test_reverse_n():
	char *hey = c"hey there"
	reverse_n(hey, 3)
	assert_strings_equal(c"yeh there", hey)

# reverse_n():
# n > strlen() would have to be checked with O(n)
# unless we explicitly do this before reversing
# right now, we use a fixed n that is assumed to be within bounds
# we could then fix via min(n, strlen(str))


void test_reverse_odd():
	char *me = c"reverseme"
	reverse(me)
	assert_strings_equal(c"emesrever", me)


void test_reverse_even():
	char *me = c"even"
	reverse(me)
	assert_strings_equal(c"neve", me)


void test_large_reverse():
	int length = 1000
	# TODO


void test_atoi():
	assert_equal(0, atoi(c"0"))
	assert_equal(0, atoi(c"00"))
	assert_equal(1, atoi(c"1"))
	assert_equal(1, atoi(c"01"))
	assert_equal(-1, atoi(c"-1"))
	assert_equal(-10, atoi(c"-10"))
	assert_equal(-100, atoi(c"-100"))
	assert_equal(-1000, atoi(c"-1000"))
	assert_equal(10, atoi(c"10"))
	assert_equal(100, atoi(c"100"))
	assert_equal(1000, atoi(c"1000"))


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
	assert1(ends_with(c"hi there", c"there"))
	assert1(ends_with(c"hi there", c"bere") == 0)
	assert1(ends_with(c"hi", c"hi"))
	assert1(ends_with(c"ahi", c"hi"))
	assert1(ends_with(c"hi", c"i"))
	assert1(ends_with(c"hi", c""))
	assert1(ends_with(c"/home/w/git/w/w.w", c".w"))


void test_str_replace_path():
	char* import_path = c"path.to.subfolder.file"
	int count = str_replace(import_path, '.', '/')
	assert_strings_equal(c"path/to/subfolder/file", import_path)
	assert_equal(3, count)


void test_str_replace_repeated():
	char* repeated = c".........."
	int count = str_replace(repeated, '.', '*')
	assert_strings_equal(c"**********", repeated)
	assert_equal(10, count)


void test_str_replace_empty():
	char* empty = c""
	int count = str_replace(empty, '.', '*')
	assert_strings_equal(c"", empty)
	assert_equal(0, count)


# Hex
void test_hex():
	assert_strings_equal(c"0x00001337", hex(4919))


void test_from_hex():
	assert_equal(0, from_hex(c"0"))
	assert_equal(1, from_hex(c"1"))
	assert_equal(31, from_hex(c"1f"))
	assert_equal(4919, from_hex(c"00001337"))
	assert_equal(305420031, from_hex(c"123456ff"))
	# todo: 0x syntax
	assert_equal(255, from_hex(c"0xff"))
	# assert_equal(0x1337, from_hex("1337"))


# Net conversions
void test_ip4_from_string(char* ips):
	assert_strings_equal(c"0x7f000001", hex(ip4_from_string(c"127.0.0.1")))
	assert_strings_equal(c"0x00000000", hex(ip4_from_string(c"0.0.0.0")))
	assert_strings_equal(c"0x01010101", hex(ip4_from_string(c"1.1.1.1")))
	assert_strings_equal(c"0xffffffff", hex(ip4_from_string(c"255.255.255.255")))


void test_mmap():
	# PROT_READ|PROT_WRITE = 3, MAP_PRIVATE|MAP_ANONYMOUS = 34
	int page = mmap(0, 4096, 3, 34)
	# error returns are small negatives (-1..-4095); mapped addresses are anything else
	asserts(c"mmap failed", (page > 0) | (page < -4095))
	save_int(page, 1337)
	assert_equal(1337, load_int(page))
	save_int(page + 4092, 42)
	assert_equal(42, load_int(page + 4092))


void test_print_registers():
	print_registers()


void test_print_stack():
	print_stack()

