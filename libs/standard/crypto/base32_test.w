# wbuild: name=crypto_base32_test x64
# wbuild: step="bin/crypto_base32_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
# Vectors below the RFC 4648 section were generated with Python 3.13's
# base64 module (b32encode / b32hexencode / b32decode / b32hexdecode).
import lib.testing
import lib.hex
import libs.standard.crypto.base32


char* b32_test_unhex(char* h, int* n):
	char* data = hex_decode(h, strlen(h), n)
	asserts(c"bad hex in test vector", data != 0)
	return data


# Encodes the hex input with both alphabets and decodes each back.
void check_base32_vector(char* input_hex, char* b32, char* b32hex):
	int n = 0
	char* data = b32_test_unhex(input_hex, &n)
	char* got = base32_encode(data, n)
	assert_strings_equal(b32, got)
	assert_equal(base32_encoded_length(n), strlen(got))
	free(got)
	got = base32hex_encode(data, n)
	assert_strings_equal(b32hex, got)
	free(got)
	int back_len = -1
	char* back = base32_decode(b32, strlen(b32), &back_len)
	asserts(c"base32 decode of a valid vector failed", back != 0)
	assert_equal(n, back_len)
	assert_bytes_equal(data, back, n)
	assert_equal(0, back[n])
	free(back)
	back = base32hex_decode(b32hex, strlen(b32hex), &back_len)
	asserts(c"base32hex decode of a valid vector failed", back != 0)
	assert_equal(n, back_len)
	assert_bytes_equal(data, back, n)
	free(back)
	free(data)


void check_decode_result(char* got, int got_len, int ok, char* want_hex):
	if (ok == 0):
		asserts(c"decoder accepted invalid input", got == 0)
		assert_equal(0, got_len)
		return
	asserts(c"decoder rejected valid input", got != 0)
	int n = 0
	char* want = b32_test_unhex(want_hex, &n)
	assert_equal(n, got_len)
	assert_bytes_equal(want, got, n)
	free(want)
	free(got)


void check_base32_decode(char* text, int casefold, int map01, int ok, char* want_hex):
	int got_len = -1
	char* got = base32_decode_opts(text, strlen(text), casefold, map01, &got_len)
	check_decode_result(got, got_len, ok, want_hex)
	if ((casefold == 0) && (map01 == 0)):
		got = base32_decode(text, strlen(text), &got_len)
		check_decode_result(got, got_len, ok, want_hex)


void check_base32hex_decode(char* text, int casefold, int ok, char* want_hex):
	int got_len = -1
	char* got = base32hex_decode_opts(text, strlen(text), casefold, &got_len)
	check_decode_result(got, got_len, ok, want_hex)


# RFC 4648 section 10.
void test_base32_rfc4648_vectors():
	check_base32_vector(c"", c"", c"")
	check_base32_vector(c"66", c"MY======", c"CO======")
	check_base32_vector(c"666f", c"MZXQ====", c"CPNG====")
	check_base32_vector(c"666f6f", c"MZXW6===", c"CPNMU===")
	check_base32_vector(c"666f6f62", c"MZXW6YQ=", c"CPNMUOG=")
	check_base32_vector(c"666f6f6261", c"MZXW6YTB", c"CPNMUOJ1")
	check_base32_vector(c"666f6f626172", c"MZXW6YTBOI======", c"CPNMUOJ1E8======")


void test_base32_python_vectors():
	check_base32_vector(c"", c"", c"")
	check_base32_vector(c"00", c"AA======", c"00======")
	check_base32_vector(c"ff", c"74======", c"VS======")
	check_base32_vector(c"00000000", c"AAAAAAA=", c"0000000=")
	check_base32_vector(c"ffffffff", c"777777Y=", c"VVVVVVO=")
	check_base32_vector(c"20202020", c"EAQCAIA=", c"40G2080=")
	check_base32_vector(c"0000000000", c"AAAAAAAA", c"00000000")
	check_base32_vector(c"2020202078", c"EAQCAIDY", c"40G2083O")
	check_base32_vector(c"68656c6c6f20776f726c64", c"NBSWY3DPEB3W64TMMQ======", c"D1IMOR3F41RMUSJCCG======")
	check_base32_vector(c"000102030405060708090a0b0c0d0e0f10111213", c"AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQT", c"000G40O40K30E209185GO38E1S8124GJ")
	check_base32_vector(c"ffffff", c"77776===", c"VVVVU===")
	check_base32_vector(c"000000", c"AAAAA===", c"00000===")
	check_base32_vector(c"a5", c"UU======", c"KK======")
	check_base32_vector(c"4dca", c"JXFA====", c"9N50====")
	check_base32_vector(c"182530", c"DASTA===", c"30IJ0===")
	check_base32_vector(c"bb1d6d13", c"XMOW2EY=", c"NCEMQ4O=")
	check_base32_vector(c"2cded6237b", c"FTPNMI33", c"5JFDC8RR")
	check_base32_vector(c"2ed91e3f721f", c"F3MR4P3SD4======", c"5RCHSFRI3S======")
	check_base32_vector(c"cb1971174494d6", c"ZMMXCF2ESTLA====", c"PCCN25Q4IJB0====")
	check_base32_vector(c"493c9d5c3460be31", c"JE6J2XBUMC7DC===", c"94U9QN1KC2V32===")
	check_base32_vector(c"201e69fedaa0eee8b9", c"EAPGT7W2UDXOROI=", c"40F6JVMQK3NEHE8=")
	check_base32_vector(c"997f5c7c2999fdafe593253cd6", c"TF7VY7BJTH627ZMTEU6NM===", c"J5VLOV19J7UQVPCJ4KUDC===")
	check_base32_vector(c"54af4dfad71427a0aeb3fee9232f8af2211f9ee491c5b10becb5563bfc1e6f", c"KSXU36WXCQT2BLVT73USGL4K6IQR7HXESHC3CC7MWVLDX7A6N4======", c"AINKRUMN2GJQ1BLJVRKI6BSAU8GHV7N4I72R22VCMLB3NV0UDS======")


# Every byte value round-trips through both alphabets.
void test_base32_binary_roundtrip():
	int n = 256
	char* data = cast(char*, malloc(n))
	for i in range(n): data[i] = i & 255
	for hex in range(2):
		char* enc = 0
		if (hex == 0): enc = base32_encode(data, n)
		else: enc = base32hex_encode(data, n)
		assert_equal(base32_encoded_length(n), strlen(enc))
		int back_len = 0
		char* back = 0
		if (hex == 0): back = base32_decode(enc, strlen(enc), &back_len)
		else: back = base32hex_decode(enc, strlen(enc), &back_len)
		asserts(c"binary round-trip failed", back != 0)
		assert_equal(n, back_len)
		assert_bytes_equal(data, back, n)
		free(back)
		free(enc)
	free(data)


# Validation, casefold and map01 cases, with Python's verdicts.
void test_base32_decode_cases():
	check_base32_decode(c"MZXW6YQ=", 0, 0, 1, c"666f6f62")
	check_base32_decode(c"mzxw6yq=", 0, 0, 0, c"")
	check_base32_decode(c"mzxw6yq=", 1, 0, 1, c"666f6f62")
	check_base32_decode(c"MZXW6YQ", 0, 0, 0, c"")
	check_base32_decode(c"MZXW6Y==", 0, 0, 0, c"")
	check_base32_decode(c"MZXW6===", 0, 0, 1, c"666f6f")
	check_base32_decode(c"MZ======", 0, 0, 1, c"66")
	check_base32_decode(c"MY======", 0, 0, 1, c"66")
	check_base32_decode(c"M=======", 0, 0, 0, c"")
	check_base32_decode(c"========", 0, 0, 0, c"")
	check_base32_decode(c"MZXW6YQ=MZXW6YQ=", 0, 0, 0, c"")
	check_base32_decode(c"MZ XW6YQ", 0, 0, 0, c"")
	check_base32_decode(c"MZXW6YQ\n", 0, 0, 0, c"")
	check_base32_decode(c"MZXW6Y1=", 0, 0, 0, c"")
	check_base32_decode(c"MZXW6Y8=", 0, 0, 0, c"")
	check_base32_decode(c"0I======", 0, 0, 0, c"")
	check_base32_decode(c"01======", 0, 76, 1, c"72")
	check_base32_decode(c"01======", 0, 73, 1, c"72")
	check_base32_decode(c"01======", 0, 108, 0, c"")
	check_base32_decode(c"01======", 1, 108, 1, c"72")
	check_base32_decode(c"ME======", 0, 0, 1, c"61")
	check_base32_decode(c"MFRGG===", 0, 0, 1, c"616263")
	check_base32_decode(c"MFRGGZA=", 0, 0, 1, c"61626364")
	check_base32_decode(c"MFRGGZDF", 0, 0, 1, c"6162636465")
	check_base32_decode(c"MZXW6YTB", 0, 0, 1, c"666f6f6261")
	check_base32_decode(c"MFRGGZDF========", 0, 0, 0, c"")
	check_base32_decode(c"", 0, 0, 1, c"")
	check_base32hex_decode(c"CPNMUOG=", 0, 1, c"666f6f62")
	check_base32hex_decode(c"cpnmuog=", 0, 0, c"")
	check_base32hex_decode(c"cpnmuog=", 1, 1, c"666f6f62")
	check_base32hex_decode(c"CPNMUOW=", 0, 0, c"")
	check_base32hex_decode(c"CPNMUOG", 0, 0, c"")
	check_base32hex_decode(c"C=======", 0, 0, c"")
	check_base32hex_decode(c"CO======", 0, 1, c"66")
	check_base32hex_decode(c"CPNG====", 0, 1, c"666f")


void test_base32_negative_length():
	int got_len = 3
	char* got = base32_decode(c"", -8, &got_len)
	asserts(c"negative length accepted", got == 0)
	assert_equal(0, got_len)
	assert_equal(0, base32_encoded_length(-1))
