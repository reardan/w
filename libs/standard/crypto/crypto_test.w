import lib.testing
import libs.standard.crypto.bytes
import libs.standard.crypto.base64
import libs.standard.crypto.hex


void assert_bytes_equal(char* want, int want_length, bytes_result got):
	assert_equal(1, got.ok)
	assert_equal(want_length, got.length)
	int i = 0
	while (i < want_length):
		assert_equal(want[i] & 255, got.data[i] & 255)
		i = i + 1


void assert_decode_fails(bytes_result got):
	assert_equal(0, got.ok)
	assert_equal(0, got.length)
	assert_equal(0, cast(int, got.data))
	assert_equal(1, cast(int, got.error) != 0)


void assert_base64_vector(char* plain, char* encoded):
	char* got = base64_b64encode(plain, strlen(plain))
	assert_strings_equal(encoded, got)
	free(got)
	bytes_result decoded = base64_b64decode(encoded)
	assert_bytes_equal(plain, strlen(plain), decoded)
	bytes_result_free(decoded)


void test_base64_rfc4648_vectors():
	assert_base64_vector(c"", c"")
	assert_base64_vector(c"f", c"Zg==")
	assert_base64_vector(c"fo", c"Zm8=")
	assert_base64_vector(c"foo", c"Zm9v")
	assert_base64_vector(c"foob", c"Zm9vYg==")
	assert_base64_vector(c"fooba", c"Zm9vYmE=")
	assert_base64_vector(c"foobar", c"Zm9vYmFy")


void test_base64_binary_round_trip():
	char* data = malloc(4)
	data[0] = 0
	data[1] = 1
	data[2] = 254
	data[3] = 255
	char* got = base64_b64encode(data, 4)
	assert_strings_equal(c"AAH+/w==", got)
	bytes_result decoded = base64_b64decode(got)
	assert_bytes_equal(data, 4, decoded)
	bytes_result_free(decoded)
	free(got)
	free(data)


void test_base64_urlsafe_vectors():
	char* data = malloc(4)
	data[0] = 0
	data[1] = 1
	data[2] = 254
	data[3] = 255
	char* got = base64_urlsafe_b64encode(data, 4)
	assert_strings_equal(c"AAH-_w==", got)
	bytes_result decoded = base64_urlsafe_b64decode(got)
	assert_bytes_equal(data, 4, decoded)
	bytes_result_free(decoded)
	free(got)
	free(data)


void test_base64_invalid_inputs():
	assert_decode_fails(base64_b64decode(c"Zg="))
	assert_decode_fails(base64_b64decode(c"Z==="))
	assert_decode_fails(base64_b64decode(c"Zm=9"))
	assert_decode_fails(base64_b64decode(c"Zm9v$==="))
	assert_decode_fails(base64_b64decode(c"AAH-_w=="))


void test_hex_vectors():
	char* empty = hex_encode(c"", 0)
	assert_strings_equal(c"", empty)
	free(empty)
	char* got = hex_encode(c"hello", 5)
	assert_strings_equal(c"68656c6c6f", got)
	free(got)
	bytes_result decoded = hex_decode(c"68656C6C6F")
	assert_bytes_equal(c"hello", 5, decoded)
	bytes_result_free(decoded)


void test_hex_binary_round_trip():
	char* data = malloc(3)
	data[0] = 0
	data[1] = 15
	data[2] = 255
	char* got = hex_encode(data, 3)
	assert_strings_equal(c"000fff", got)
	bytes_result decoded = hex_decode(got)
	assert_bytes_equal(data, 3, decoded)
	bytes_result_free(decoded)
	free(got)
	free(data)


void test_hex_invalid_inputs():
	assert_decode_fails(hex_decode(c"0"))
	assert_decode_fails(hex_decode(c"xx"))
	assert_decode_fails(hex_decode(c"12xz"))
