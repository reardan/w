# wbuild: name=crypto_base64_test x64
import lib.testing
import libs.standard.crypto.base64


void assert_bytes_equal(char* want, char* got, int len):
	int i = 0
	while (i < len):
		assert_equal(want[i] & 255, got[i] & 255)
		i = i + 1


# One encode + decode round-trip against a known text vector.
void check_base64_vector(char* plain, char* encoded):
	int plain_len = strlen(plain)
	char* got = base64_encode(plain, plain_len)
	assert_strings_equal(encoded, got)
	assert_equal(base64_encoded_length(plain_len), strlen(got))
	free(got)

	int decoded_len = 0
	char* back = base64_decode(encoded, strlen(encoded), &decoded_len)
	asserts(c"decode of a valid vector returned 0", back != 0)
	assert_equal(plain_len, decoded_len)
	assert_strings_equal(plain, back)
	free(back)


void assert_base64_rejected(char* text):
	int decoded_len = 7
	char* got = base64_decode(text, strlen(text), &decoded_len)
	if (got != 0):
		print2(c"base64_decode accepted invalid input: ")
		println2(text)
		exit(1)
	assert_equal(0, decoded_len)


# RFC 4648 section 10 test vectors, both directions.
void test_base64_rfc4648_vectors():
	check_base64_vector(c"", c"")
	check_base64_vector(c"f", c"Zg==")
	check_base64_vector(c"fo", c"Zm8=")
	check_base64_vector(c"foo", c"Zm9v")
	check_base64_vector(c"foob", c"Zm9vYg==")
	check_base64_vector(c"fooba", c"Zm9vYmE=")
	check_base64_vector(c"foobar", c"Zm9vYmFy")


# Every byte value survives a round-trip, including embedded NULs.
void test_base64_binary_roundtrip():
	int n = 256
	char* data = malloc(n)
	int i = 0
	while (i < n):
		data[i] = i & 255
		i = i + 1
	char* encoded = base64_encode(data, n)
	assert_equal(base64_encoded_length(n), strlen(encoded))
	int decoded_len = 0
	char* back = base64_decode(encoded, strlen(encoded), &decoded_len)
	asserts(c"binary round-trip decode returned 0", back != 0)
	assert_equal(n, decoded_len)
	assert_bytes_equal(data, back, n)
	free(back)
	free(encoded)
	free(data)


# All-'A' groups exercise the zero-value path and padded final quantum.
void test_base64_decode_padding_values():
	int decoded_len = 0
	char* got = base64_decode(c"AAA=", 4, &decoded_len)
	asserts(c"decode of AAA= returned 0", got != 0)
	assert_equal(2, decoded_len)
	assert_equal(0, got[0] & 255)
	assert_equal(0, got[1] & 255)
	free(got)


void test_base64_decode_rejects_bad_length():
	assert_base64_rejected(c"Z")
	assert_base64_rejected(c"Zg")
	assert_base64_rejected(c"Zg=")
	assert_base64_rejected(c"Zm9vYg==A")


void test_base64_decode_rejects_bad_characters():
	assert_base64_rejected(c"Zm9$")
	assert_base64_rejected(c"Zm9v\n")
	assert_base64_rejected(c"Zm 9vYQ==")
	assert_base64_rejected(c"Zm9v....")


void test_base64_decode_rejects_bad_padding():
	# '=' anywhere but the trailing positions of the final quantum.
	assert_base64_rejected(c"Zg==Zm9v")
	assert_base64_rejected(c"Z=g=")
	assert_base64_rejected(c"=Zg=")
	assert_base64_rejected(c"====")
	assert_base64_rejected(c"A===")


void test_base64_decode_rejects_nonzero_trailing_bits():
	# Canonical forms are "Zm8=" and "Zg=="; these set the padding bits.
	assert_base64_rejected(c"Zm9=")
	assert_base64_rejected(c"Zh==")


# RFC 4648 section 10 base16 vectors (we emit lowercase).
void test_hex_encode_vectors():
	char* got = hex_encode(c"", 0)
	assert_strings_equal(c"", got)
	free(got)
	got = hex_encode(c"f", 1)
	assert_strings_equal(c"66", got)
	free(got)
	got = hex_encode(c"fo", 2)
	assert_strings_equal(c"666f", got)
	free(got)
	got = hex_encode(c"foobar", 6)
	assert_strings_equal(c"666f6f626172", got)
	free(got)


void test_hex_decode_both_cases():
	int decoded_len = 0
	char* got = hex_decode(c"666f6f", 6, &decoded_len)
	asserts(c"hex decode (lowercase) returned 0", got != 0)
	assert_equal(3, decoded_len)
	assert_strings_equal(c"foo", got)
	free(got)

	got = hex_decode(c"666F6F", 6, &decoded_len)
	asserts(c"hex decode (uppercase) returned 0", got != 0)
	assert_equal(3, decoded_len)
	assert_strings_equal(c"foo", got)
	free(got)

	got = hex_decode(c"", 0, &decoded_len)
	asserts(c"hex decode of empty input returned 0", got != 0)
	assert_equal(0, decoded_len)
	free(got)


void test_hex_binary_roundtrip():
	int n = 256
	char* data = malloc(n)
	int i = 0
	while (i < n):
		data[i] = i & 255
		i = i + 1
	char* encoded = hex_encode(data, n)
	assert_equal(2 * n, strlen(encoded))
	int decoded_len = 0
	char* back = hex_decode(encoded, strlen(encoded), &decoded_len)
	asserts(c"hex round-trip decode returned 0", back != 0)
	assert_equal(n, decoded_len)
	assert_bytes_equal(data, back, n)
	free(back)
	free(encoded)
	free(data)


void test_hex_decode_rejects_invalid():
	int decoded_len = 5
	char* got = hex_decode(c"abc", 3, &decoded_len)
	asserts(c"hex decode accepted an odd length", got == 0)
	assert_equal(0, decoded_len)
	got = hex_decode(c"0g", 2, &decoded_len)
	asserts(c"hex decode accepted 'g'", got == 0)
	got = hex_decode(c"4 ", 2, &decoded_len)
	asserts(c"hex decode accepted a space", got == 0)
	got = hex_decode(c"0x41", 4, &decoded_len)
	asserts(c"hex decode accepted an 0x prefix", got == 0)
