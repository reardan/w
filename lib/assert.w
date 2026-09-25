import lib.lib
import lib.stack_trace


void asserts(char* s, int condition):
	if (condition == 0):
		println2(s)
		print_stack_trace()
		exit(1)


# todo cannot name the same as the file lol!
#void assert1(int condition):
void assert1(int condition):
	if (condition == 0):
		println2(c"Assertion2 failed.")
		print_stack_trace()
		exit(1)


void assert_equal(int want, int got):
	if (want != got):
		print2(c"Assertion failed.  wanted int(")
		print2(itoa(want))
		print2(c") got int(")
		print2(itoa(got))
		println2(c")")
		print_stack_trace()
		exit(1)


void assert_equal_hex(int want, int got):
	if (want != got):
		print2(c"Assertion failed.  wanted ")
		print2(hex(want))
		print2(c" got ")
		print2(hex(got))
		println2(c"")
		print_stack_trace()
		exit(1)


# A null pointer prints as (null) and equals only another null, so a
# missing string fails with a message instead of crashing in strcmp.
char* assert_text(char* s):
	if (s == 0):
		return c"(null)"
	return s


void assert_strings_equal(char* want, char* got):
	int same = want == got
	if ((want != 0) && (got != 0)):
		same = strcmp(got, want) == 0
	if (same == 0):
		print2(c"Assertion failed: wanted '")
		print2(assert_text(want))
		print2(c"' got '")
		print2(assert_text(got))
		println2(c"'")
		print_stack_trace()
		exit(1)


# 1 when needle occurs in haystack (a null haystack contains nothing).
int assert_has(char* haystack, char* needle):
	if (haystack == 0):
		return 0
	int i = 0
	while (1):
		int j = 0
		while ((needle[j] != 0) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (needle[j] == 0):
			return 1
		if (haystack[i] == 0):
			return 0
		i = i + 1
	return 0


void assert_substring(char* haystack, char* needle, int want):
	if (assert_has(haystack, needle) != want):
		if (want):
			print2(c"Assertion failed: expected to find '")
		else:
			print2(c"Assertion failed: expected NOT to find '")
		print2(needle)
		print2(c"' in: ")
		println2(assert_text(haystack))
		print_stack_trace()
		exit(1)


void assert_contains(char* haystack, char* needle):
	assert_substring(haystack, needle, 1)


void assert_lacks(char* haystack, char* needle):
	assert_substring(haystack, needle, 0)


# The first length bytes of got equal want's.
void assert_bytes_equal(char* want, char* got, int length):
	for i in range(length):
		if ((want[i] & 255) != (got[i] & 255)):
			print2(c"Assertion failed: bytes differ at offset ")
			print2(itoa(i))
			print2(c": wanted ")
			print2(itoa(want[i] & 255))
			print2(c" got ")
			println2(itoa(got[i] & 255))
			print_stack_trace()
			exit(1)
