# wbuild: x64
# wbuild: step="bin/secrets_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import lib.container
import libs.standard.crypto.secrets


int secrets_test_is_hex(int ch):
	return ((ch >= '0') && (ch <= '9')) || ((ch >= 'a') && (ch <= 'f'))


int secrets_test_is_urlsafe(int ch):
	if ((ch >= 'A') && (ch <= 'Z')): return 1
	if ((ch >= 'a') && (ch <= 'z')): return 1
	if ((ch >= '0') && (ch <= '9')): return 1
	return (ch == '-') || (ch == '_')


void test_token_bytes():
	char* a = cast(char*, malloc(32))
	char* b = cast(char*, malloc(32))
	assert_equal(1, secrets_token_bytes(a, 32))
	assert_equal(1, secrets_token_bytes(b, 32))
	# 2^-256 chance of a false failure.
	assert_equal(0, secrets_compare_digest(a, 32, b, 32))
	assert_equal(1, secrets_token_bytes(a, 0))
	assert_equal(0, secrets_token_bytes(a, -1))
	free(b)
	free(a)


void test_token_hex():
	char* t = secrets_token_hex(secrets_default_nbytes)
	assert_equal(64, strlen(t))
	for i in range(64): assert1(secrets_test_is_hex(t[i]))
	char* u = secrets_token_hex(secrets_default_nbytes)
	assert_equal(0, secrets_compare_digest_str(t, u))
	char* e = secrets_token_hex(0)
	assert_equal(0, strlen(e))
	assert_equal(0, cast(int, secrets_token_hex(-1)))
	free(e)
	free(u)
	free(t)


# base64url without padding: ceil(4n/3) characters for every remainder.
void test_token_urlsafe():
	for n in range(1, 40):
		char* t = secrets_token_urlsafe(n)
		int want = (n * 4 + 2) / 3
		assert_equal(want, strlen(t))
		for i in range(want): assert1(secrets_test_is_urlsafe(t[i]))
		free(t)
	# Over many tokens both substituted characters show up and '+', '/'
	# and '=' never do.
	int dash = 0
	int under = 0
	for k in range(200):
		char* s = secrets_token_urlsafe(48)
		for i in range(64):
			if (s[i] == '-'): dash = dash + 1
			if (s[i] == '_'): under = under + 1
		free(s)
	assert1(dash > 0)
	assert1(under > 0)
	char* z = secrets_token_urlsafe(0)
	assert_equal(0, strlen(z))
	free(z)


void test_randbelow():
	list[int] seen = new list[int]
	for i in range(6): seen.push(0)
	for i in range(600):
		int v = secrets_randbelow(6)
		assert1((v >= 0) && (v < 6))
		seen[v] = seen[v] + 1
	for i in range(6): assert1(seen[i] > 30)
	for i in range(20): assert_equal(0, secrets_randbelow(1))
	int big = secrets_randbelow(1000000007)
	assert1((big >= 0) && (big < 1000000007))
	list_free[int](seen)


void test_compare_digest():
	assert_equal(1, secrets_compare_digest(c"abcdef", 6, c"abcdef", 6))
	# Difference only in the last byte, only in the first, only in a high bit.
	assert_equal(0, secrets_compare_digest(c"abcdef", 6, c"abcdeg", 6))
	assert_equal(0, secrets_compare_digest(c"abcdef", 6, c"Abcdef", 6))
	char* hi = cast(char*, malloc(2))
	hi[0] = 'a' + 128
	hi[1] = 0
	assert_equal(0, secrets_compare_digest(c"a", 1, hi, 1))
	free(hi)
	# Length mismatch is unequal even when one is a prefix of the other.
	assert_equal(0, secrets_compare_digest(c"abc", 3, c"abcdef", 6))
	assert_equal(0, secrets_compare_digest(c"abcdef", 6, c"abc", 3))
	assert_equal(0, secrets_compare_digest(c"", 0, c"a", 1))
	assert_equal(1, secrets_compare_digest(c"", 0, c"", 0))
	assert_equal(0, secrets_compare_digest(c"a", -1, c"a", 1))
	# Embedded NULs are compared like any other byte.
	assert_equal(1, secrets_compare_digest(c"a\0b", 3, c"a\0b", 3))
	assert_equal(0, secrets_compare_digest(c"a\0b", 3, c"a\0c", 3))
	assert_equal(1, secrets_compare_digest_str(c"token", c"token"))
	assert_equal(0, secrets_compare_digest_str(c"token", c"tokens"))
	assert_equal(0, secrets_compare_digest_str(c"token", c"tokeN"))
