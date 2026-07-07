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
	assert_equal(cast(int, a), cast(int, b))
	free(b)


void test_malloc_reuse_loop():
	# A steady alloc/free cycle must not leak: the same block comes back
	int first = cast(int, malloc(1000))
	free(cast(void*, first))
	int i = 0
	while (i < 1000):
		int p = cast(int, malloc(1000))
		assert_equal(first, p)
		free(cast(void*, p))
		i = i + 1


void test_malloc_split():
	char* big = malloc(256)
	free(big)
	# A smaller request splits the free block instead of growing the heap
	char* head = malloc(64)
	assert_equal(cast(int, big), cast(int, head))
	char* rest = malloc(64)
	# The split block starts after the first payload plus a two-word header
	assert_equal(big + 64 + 2 * __word_size__, cast(int, rest))
	free(head)
	free(rest)


void test_malloc_zero_and_alignment():
	int a = cast(int, malloc(0))
	int b = cast(int, malloc(1))
	assert1(a != 0)
	assert1(b != 0)
	assert1(a != b)
	# Payloads are 8-byte aligned
	assert_equal(0, a & 7)
	assert_equal(0, b & 7)
	free(cast(void*, a))
	free(cast(void*, b))


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
	# Reverse mutates in place, so operate on a heap copy rather than the
	# string literal (which lives in the now read-only code segment).
	char *hey = strclone(c"hey there")
	reverse_n(hey, 3)
	assert_strings_equal(c"yeh there", hey)
	free(hey)

# reverse_n():
# n > strlen() would have to be checked with O(n)
# unless we explicitly do this before reversing
# right now, we use a fixed n that is assumed to be within bounds
# we could then fix via min(n, strlen(str))


void test_reverse_odd():
	char *me = strclone(c"reverseme")
	reverse(me)
	assert_strings_equal(c"emesrever", me)
	free(me)


void test_reverse_even():
	char *me = strclone(c"even")
	reverse(me)
	assert_strings_equal(c"neve", me)
	free(me)


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
	char* import_path = strclone(c"path.to.subfolder.file")
	int count = str_replace(import_path, '.', '/')
	assert_strings_equal(c"path/to/subfolder/file", import_path)
	assert_equal(3, count)
	free(import_path)


void test_str_replace_repeated():
	char* repeated = strclone(c"..........")
	int count = str_replace(repeated, '.', '*')
	assert_strings_equal(c"**********", repeated)
	assert_equal(10, count)
	free(repeated)


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
	assert_equal(31, from_hex(c"1F"))
	assert_equal(305420031, from_hex(c"123456FF"))
	assert_equal(0x1F01, from_hex(c"1f01"))
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
	save_int(cast(char*, page), 1337)
	assert_equal(1337, load_int(cast(char*, page)))
	save_int(page + 4092, 42)
	assert_equal(42, load_int(page + 4092))


# The repl/wdbg in-process model maps an 8MB MAP_32BIT code buffer that
# can land directly above a low-randomized brk base, making every later
# brk growth fail (brk returns the old break, not an errno). malloc must
# then fall back to mmap chunks instead of handing out unmapped memory.
void test_malloc_survives_blocked_brk():
	# Force the allocator to touch the break first, then wall it off
	# (page-aligned up: the kernel's initial break need not be aligned,
	# and an unaligned MAP_FIXED would fail and leave brk growable)
	free(malloc(16))
	int break_now = brk(0)
	int guard_at = (break_now + 4095) / 4096 * 4096
	# PROT_NONE = 0, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED = 50
	int guard = mmap(guard_at, 4096, 0, 50)
	asserts(c"guard mmap failed", guard == guard_at)
	# Exhaust the current chunk and force several growth cycles
	int i = 0
	while (i < 64):
		char* block = malloc(16384)
		asserts(c"malloc returned 0 with brk blocked", block != 0)
		block[0] = i
		block[16383] = i + 1
		assert_equal(i, block[0])
		assert_equal(i + 1, block[16383])
		i = i + 1


void test_print_registers():
	print_registers()


void test_print_stack():
	print_stack()

