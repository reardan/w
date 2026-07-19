# wbuild: name=crypto_random_test x64
import lib.testing
import libs.standard.crypto.random


int count_zero_bytes(char* buf, int len):
	int zeros = 0
	int i = 0
	while (i < len):
		if ((buf[i] & 255) == 0):
			zeros = zeros + 1
		i = i + 1
	return zeros


# The requested length is filled and (with probability 1 - 2^-512) the
# result is not all zeros.
void test_random_bytes_fills_buffer():
	int n = 64
	char* buf = malloc(n)
	int i = 0
	while (i < n):
		buf[i] = 0
		i = i + 1
	assert_equal(1, random_bytes(buf, n))
	asserts(c"random_bytes returned 64 zero bytes", count_zero_bytes(buf, n) < n)
	free(buf)


# Two independent draws differ (collision probability 2^-256).
void test_random_two_draws_differ():
	int n = 32
	char* a = malloc(n)
	char* b = malloc(n)
	assert_equal(1, random_bytes(a, n))
	assert_equal(1, random_bytes(b, n))
	int same = 1
	int i = 0
	while (i < n):
		if ((a[i] & 255) != (b[i] & 255)):
			same = 0
		i = i + 1
	asserts(c"two 32-byte draws were identical", same == 0)
	free(b)
	free(a)


# Exactly len bytes are written: sentinel bytes past the end survive.
void test_random_bytes_respects_length():
	int total = 48
	int ask = 16
	char* buf = malloc(total)
	int i = 0
	while (i < total):
		buf[i] = 'Z'
		i = i + 1
	assert_equal(1, random_bytes(buf, ask))
	i = ask
	while (i < total):
		assert_equal('Z', buf[i] & 255)
		i = i + 1
	free(buf)


void test_random_zero_length():
	char* buf = malloc(4)
	buf[0] = 'w'
	assert_equal(1, random_bytes(buf, 0))
	assert_equal('w', buf[0] & 255)
	free(buf)


void test_random_negative_length_fails():
	char* buf = malloc(4)
	assert_equal(0, random_bytes(buf, 0 - 1))
	assert_equal(0, random_urandom_fill(buf, 0 - 1))
	free(buf)


# The /dev/urandom fallback path works on its own (on arm64_darwin it is
# the only path, since Darwin has no getrandom syscall).
void test_random_urandom_fallback_path():
	int n = 32
	char* buf = malloc(n)
	int i = 0
	while (i < n):
		buf[i] = 0
		i = i + 1
	assert_equal(1, random_urandom_fill(buf, n))
	asserts(c"urandom fallback returned 32 zero bytes", count_zero_bytes(buf, n) < n)
	free(buf)
