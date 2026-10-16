# wbuild: name=formats_struct_test x64
# wbuild: step="bin/formats_struct_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
#
# Byte-exact tables below come from CPython's struct module
# (struct_test_table_rows and friends at the end of this file). Native
# ('@') rows are tagged "64" (CPython on x86-64) or "32" (the same values
# packed with an equivalent explicit-padding '<' format under the i386
# ABI: l/n/N/P 4 bytes, q/Q/d aligned to 4).
#
# Value specs, one space-separated token per item:
#   i<decimal>  STRUCT_INT               u<8 hex>   STRUCT_INT from a 32-bit pattern
#   q<16 hex>   STRUCT_INT64 (hi, lo)    Q<16 hex>  STRUCT_UINT64 (hi, lo)
#   ?0 / ?1     STRUCT_BOOL              f<8 hex>   STRUCT_FLOAT bits
#   d<16 hex>   STRUCT_DOUBLE (hi, lo)   w<8 hex>   STRUCT_FLOAT bits (packed with 'd')
#   s<hex>      STRUCT_BYTES
import lib.testing
import lib.hex
import libs.standard.formats.struct


int struct_test_hex(char* s, int n):
	int v = 0
	for k in range(n): v = (v << 4) | hex_decode_char(s[k])
	return v


int struct_test_decimal(char* s, int n):
	int neg = 0
	int k = 0
	if (n > 0 && s[0] == '-'):
		neg = 1
		k = 1
	int v = 0
	while (k < n):
		v = v * 10 + (s[k] - '0')
		k = k + 1
	if (neg): return 0 - v
	return v


# Builds a struct_values from a value spec (see the header).
struct_values* struct_test_values(char* spec):
	struct_values* v = struct_values_new()
	int i = 0
	while (spec[i] != 0):
		if (spec[i] == ' '):
			i = i + 1
			continue
		int start = i
		while (spec[i] != 0 && spec[i] != ' '): i = i + 1
		int kind = spec[start]
		char* text = &spec[start + 1]
		int n = i - start - 1
		if (kind == 'i'): struct_values_add_int(v, struct_test_decimal(text, n))
		elif (kind == 'u'): struct_values_add_int(v, struct_test_hex(text, 8))
		elif (kind == 'q'): struct_values_add_int64(v, struct_test_hex(text, 8), struct_test_hex(&text[8], 8))
		elif (kind == 'Q'): struct_values_add_uint64(v, struct_test_hex(text, 8), struct_test_hex(&text[8], 8))
		elif (kind == '?'): struct_values_add_bool(v, text[0] == '1')
		elif (kind == 'f' || kind == 'w'): struct_values_add_float_bits(v, struct_test_hex(text, 8))
		elif (kind == 'd'): struct_values_add_double_bits(v, struct_test_hex(text, 8), struct_test_hex(&text[8], 8))
		elif (kind == 's'):
			int len = 0
			char* raw = hex_decode(text, n, &len)
			struct_values_add_bytes(v, raw, len)
			free(raw)
		else: asserts(c"bad test spec token", 0)
	return v


# Checks that got matches the expected-values spec item by item.
void struct_test_check_values(char* fmt, char* spec, struct_values* got):
	struct_values* want = struct_test_values(spec)
	if (struct_values_length(want) != struct_values_length(got)):
		println2(fmt)
	assert_equal(struct_values_length(want), struct_values_length(got))
	int token = 0
	int i = 0
	while (spec[i] != 0):
		if (spec[i] == ' '):
			i = i + 1
			continue
		int kind = spec[i]
		while (spec[i] != 0 && spec[i] != ' '): i = i + 1
		int k = token
		token = token + 1
		int got_kind = struct_values_kind(got, k)
		if (kind == 'i' || kind == 'u'):
			assert_equal(STRUCT_INT, got_kind)
			assert_equal(struct_values_int(want, k), struct_values_int(got, k))
		elif (kind == '?'):
			assert_equal(STRUCT_BOOL, got_kind)
			assert_equal(struct_values_int(want, k), struct_values_int(got, k))
		elif (kind == 'q' || kind == 'Q' || kind == 'd'):
			if (got_kind != struct_values_kind(want, k)): println2(fmt)
			assert_equal(struct_values_kind(want, k), got_kind)
			assert_equal(struct_values_hi(want, k), struct_values_hi(got, k))
			assert_equal(struct_values_lo(want, k), struct_values_lo(got, k))
		elif (kind == 'f'):
			assert_equal(STRUCT_FLOAT, got_kind)
			assert_equal(struct_values_lo(want, k), struct_values_lo(got, k))
		else:
			assert_equal(STRUCT_BYTES, got_kind)
			assert_equal(struct_values_bytes_length(want, k), struct_values_bytes_length(got, k))
			assert_bytes_equal(struct_values_bytes(want, k), struct_values_bytes(got, k), struct_values_bytes_length(want, k))
	struct_values_free(want)


void struct_test_row(list[char*] t, char* target, char* fmt, char* packed_in, char* packed_hex, char* unpacked):
	t.push(target)
	t.push(fmt)
	t.push(packed_in)
	t.push(packed_hex)
	t.push(unpacked)


int struct_test_row_applies(char* target):
	if (target[0] == 'a'): return 1
	if (target[0] == '6'): return __word_size__ == 8
	return __word_size__ == 4


void struct_test_table_rows(list[char*] t);
void struct_test_calcsize_rows(list[char*] formats, list[int] sizes);
void struct_test_error_rows(list[char*] t);


void test_pack_unpack_table():
	list[char*] t = new list[char*]
	struct_test_table_rows(t)
	int ran = 0
	int r = 0
	while (r < t.length):
		char* fmt = t[r + 1]
		if (struct_test_row_applies(t[r])):
			ran = ran + 1
			struct_values* v = struct_test_values(t[r + 2])
			int n = 0
			char* packed = struct_pack(fmt, v, &n)
			if (packed == 0):
				println2(fmt)
				println2(struct_error())
			assert1(packed != 0)
			char* hex = hex_encode(packed, n)
			if (strcmp(hex, t[r + 3]) != 0): println2(fmt)
			assert_strings_equal(t[r + 3], hex)
			assert_equal(n, struct_calcsize(fmt))
			struct_values* back = struct_unpack(fmt, packed, n)
			assert1(back != 0)
			struct_test_check_values(fmt, t[r + 4], back)
			struct_values_free(back)
			free(hex)
			free(packed)
			struct_values_free(v)
		r = r + 5
	assert1(ran > 200)
	t.free()


void test_calcsize_table():
	list[char*] formats = new list[char*]
	list[int] sizes = new list[int]
	struct_test_calcsize_rows(formats, sizes)
	for k in range(formats.length):
		int got = struct_calcsize(formats[k])
		if (got != sizes[k]): println2(formats[k])
		assert_equal(sizes[k], got)
		if (got < 0): assert1(strlen(struct_error()) > 0)
		else: assert_equal(0, strlen(struct_error()))
	formats.free()
	sizes.free()


void test_native_calcsize():
	assert_equal(__word_size__, struct_calcsize(c"l"))
	assert_equal(__word_size__, struct_calcsize(c"@P"))
	assert_equal(4, struct_calcsize(c"<l"))
	if (__word_size__ == 8):
		assert_equal(16, struct_calcsize(c"bd"))
		assert_equal(24, struct_calcsize(c"@bqb0q"))
	else:
		assert_equal(12, struct_calcsize(c"bd"))
		assert_equal(16, struct_calcsize(c"@bqb0q"))


void test_pack_errors():
	list[char*] t = new list[char*]
	struct_test_error_rows(t)
	int r = 0
	while (r < t.length):
		struct_values* v = struct_test_values(t[r + 1])
		int n = 99
		char* packed = struct_pack(t[r], v, &n)
		if (packed != 0):
			println2(t[r])
			println2(t[r + 1])
		assert1(packed == 0)
		assert_equal(0, n)
		assert1(strlen(struct_error()) > 0)
		struct_values_free(v)
		r = r + 2
	t.free()


void test_unsigned_word_pattern():
	# A 32-bit target has no positive int above 2**31 - 1, so 'I' takes the
	# raw pattern there; 64-bit targets range-check like Python.
	struct_values* v = struct_values_new()
	struct_values_add_int(v, 0 - 1)
	int n = 0
	char* packed = struct_pack(c"<I", v, &n)
	if (__word_size__ == 4):
		assert1(packed != 0)
		assert_bytes_equal(c"\xff\xff\xff\xff", packed, 4)
		free(packed)
	else:
		assert1(packed == 0)
		assert_strings_equal(c"argument out of range", struct_error())
	struct_values_free(v)
	# Likewise 2**31 is only the pattern of -2**31 on a 32-bit target.
	v = struct_test_values(c"u80000000")
	packed = struct_pack(c"<i", v, &n)
	if (__word_size__ == 4):
		assert1(packed != 0)
		assert_bytes_equal(c"\x00\x00\x00\x80", packed, 4)
		free(packed)
	else: assert1(packed == 0)
	struct_values_free(v)


void test_unpack_errors():
	char* buf = c"\x01\x02\x03\x04\x05"
	assert1(struct_unpack(c"<i", buf, 5) == 0)
	assert1(strlen(struct_error()) > 0)
	assert1(struct_unpack(c"<i", buf, 3) == 0)
	assert1(struct_unpack(c"<k", buf, 4) == 0)
	assert_strings_equal(c"bad char in struct format", struct_error())
	assert1(struct_unpack_from(c"<i", buf, 5, 2) == 0)
	assert1(struct_unpack_from(c"<i", buf, 5, 0 - 6) == 0)
	assert1(struct_unpack_from(c"<i", buf, 5, 0 - 3) == 0)
	struct_values* v = struct_unpack_from(c"<i", buf, 5)
	assert_equal(67305985, struct_values_int(v, 0))
	assert_equal(0, strlen(struct_error()))
	struct_values_free(v)


void test_unpack_from_offsets():
	char* buf = c"\x00\x11\x22\x33\x44\x55\x66\x77\x88"
	struct_values* v = struct_unpack_from(c">H", buf, 9, 1)
	assert_equal(4386, struct_values_int(v, 0))
	struct_values_free(v)
	v = struct_unpack_from(c">HB", buf, 9, 0 - 3)
	assert_equal(26231, struct_values_int(v, 0))
	assert_equal(136, struct_values_int(v, 1))
	struct_values_free(v)
	v = struct_unpack_from(c"<Q", buf, 9, 1)
	assert_equal(STRUCT_UINT64, struct_values_kind(v, 0))
	assert_equal_hex(struct_test_hex(c"88776655", 8), struct_values_hi(v, 0))
	assert_equal_hex(struct_test_hex(c"44332211", 8), struct_values_lo(v, 0))
	struct_values_free(v)
	v = struct_unpack_from(c"0s", buf, 9, 9)
	assert_equal(0, struct_values_bytes_length(v, 0))
	struct_values_free(v)


void test_pack_into_offsets():
	char* buf = cast(char*, malloc(8))
	for k in range(8): buf[k] = 'z'
	struct_values* v = struct_values_new()
	struct_values_add_int(v, 258)
	struct_values_add_string(v, c"ab")
	assert_equal(1, struct_pack_into(c">h2s", buf, 8, 2, v))
	assert_bytes_equal(c"zz\x01\x02abzz", buf, 8)
	assert_equal(1, struct_pack_into(c"<h2s", buf, 8, 0 - 4, v))
	assert_bytes_equal(c"zz\x01\x02\x02\x01ab", buf, 8)
	# Too small, out of range, or a bad value: buf is left untouched.
	assert_equal(0, struct_pack_into(c"<h2s", buf, 8, 5, v))
	assert_equal(0, struct_pack_into(c"<h2s", buf, 8, 0 - 9, v))
	assert_equal(0, struct_pack_into(c"<b2s", buf, 8, 0, v))
	assert_bytes_equal(c"zz\x01\x02\x02\x01ab", buf, 8)
	struct_values_free(v)
	free(buf)


void test_accessors():
	struct_values* v = struct_values_new()
	struct_values_add_int(v, 0 - 5)
	struct_values_add_float(v, 1.5)
	struct_values_add_int64(v, 0, 7)
	struct_values_add_uint64(v, 1, 0)
	struct_values_add_bool(v, 42)
	struct_values_add_int64(v, 0 - 1, 0 - 3)
	assert_equal(6, struct_values_length(v))
	assert_equal(bytes_mask32(), struct_values_hi(v, 0))
	assert_equal(bytes_mask32() - 4, struct_values_lo(v, 0))
	assert_near(1.5, struct_values_float(v, 1))
	assert_equal(7, struct_values_int(v, 2))
	int out = 99
	if (__word_size__ == 8):
		assert_equal(1, struct_values_int_checked(v, 3, &out))
		assert_equal(1, out >> 32)
	else:
		assert_equal(0, struct_values_int_checked(v, 3, &out))
		assert_equal(0, out)
	assert_equal(1, struct_values_bool(v, 4))
	assert_equal(0 - 3, struct_values_int(v, 5))
	int n = 0
	char* packed = struct_pack(c"<ifqQ?q", v, &n)
	assert_equal(33, n)
	char* hex = hex_encode(packed, n)
	assert_strings_equal(c"fbffffff0000c03f0700000000000000000000000100000001fdffffffffffffff", hex)
	free(hex)
	free(packed)
	struct_values_free(v)


void test_float_into_double():
	# A W float packed with 'd' widens exactly (Python: pack('<d', float32 value)).
	struct_values* v = struct_values_new()
	struct_values_add_float(v, 0.1)
	struct_values_add_float(v, 0.0 - 2.0)
	int n = 0
	char* packed = struct_pack(c">dd", v, &n)
	char* hex = hex_encode(packed, n)
	assert_strings_equal(c"3fb99999a0000000c000000000000000", hex)
	free(hex)
	free(packed)
	struct_values_free(v)


# Generated by python3 struct (231 rows): target, format, pack input, packed hex, unpack output.
void struct_test_table_rows(list[char*] t):
	struct_test_row(t, c"all", c"<b", c"i-128", c"80", c"i-128")
	struct_test_row(t, c"all", c"<b", c"i127", c"7f", c"i127")
	struct_test_row(t, c"all", c"<B", c"i0", c"00", c"i0")
	struct_test_row(t, c"all", c"<B", c"i255", c"ff", c"i255")
	struct_test_row(t, c"all", c"<h", c"i-32768", c"0080", c"i-32768")
	struct_test_row(t, c"all", c"<h", c"i12345", c"3930", c"i12345")
	struct_test_row(t, c"all", c"<H", c"i65535", c"ffff", c"i65535")
	struct_test_row(t, c"all", c"<i", c"i-2147483648", c"00000080", c"i-2147483648")
	struct_test_row(t, c"all", c"<i", c"i2147483647", c"ffffff7f", c"i2147483647")
	struct_test_row(t, c"all", c"<I", c"uffffffff", c"ffffffff", c"uffffffff")
	struct_test_row(t, c"all", c"<I", c"u80000000", c"00000080", c"u80000000")
	struct_test_row(t, c"all", c"<l", c"i-7", c"f9ffffff", c"i-7")
	struct_test_row(t, c"all", c"<L", c"udeadbeef", c"efbeadde", c"udeadbeef")
	struct_test_row(t, c"all", c"<q", c"i-1", c"ffffffffffffffff", c"qffffffffffffffff")
	struct_test_row(t, c"all", c"<q", c"q8000000000000000", c"0000000000000080", c"q8000000000000000")
	struct_test_row(t, c"all", c"<q", c"q7fffffffffffffff", c"ffffffffffffff7f", c"q7fffffffffffffff")
	struct_test_row(t, c"all", c"<q", c"q123456789abcdef0", c"f0debc9a78563412", c"q123456789abcdef0")
	struct_test_row(t, c"all", c"<Q", c"Qffffffffffffffff", c"ffffffffffffffff", c"Qffffffffffffffff")
	struct_test_row(t, c"all", c"<Q", c"q0102030405060708", c"0807060504030201", c"Q0102030405060708")
	struct_test_row(t, c"all", c"<Q", c"i5", c"0500000000000000", c"Q0000000000000005")
	struct_test_row(t, c"all", c"<f", c"f3fc00000", c"0000c03f", c"f3fc00000")
	struct_test_row(t, c"all", c"<f", c"f80000000", c"00000080", c"f80000000")
	struct_test_row(t, c"all", c"<f", c"f7f800000", c"0000807f", c"f7f800000")
	struct_test_row(t, c"all", c"<f", c"f00034447", c"47440300", c"f00034447")
	struct_test_row(t, c"all", c"<d", c"d3ff8000000000000", c"000000000000f83f", c"d3ff8000000000000")
	struct_test_row(t, c"all", c"<d", c"dc000000000000000", c"00000000000000c0", c"dc000000000000000")
	struct_test_row(t, c"all", c"<d", c"d3fb999999999999a", c"9a9999999999b93f", c"d3fb999999999999a")
	struct_test_row(t, c"all", c"<d", c"dfff0000000000000", c"000000000000f0ff", c"dfff0000000000000")
	struct_test_row(t, c"all", c"<d", c"d0000000000000001", c"0100000000000000", c"d0000000000000001")
	struct_test_row(t, c"all", c"<?", c"?1", c"01", c"?1")
	struct_test_row(t, c"all", c"<?", c"?0", c"00", c"?0")
	struct_test_row(t, c"all", c"<c", c"sff", c"ff", c"sff")
	struct_test_row(t, c"all", c"<4s", c"s6162", c"61620000", c"s61620000")
	struct_test_row(t, c"all", c"<2s", c"s61626364", c"6162", c"s6162")
	struct_test_row(t, c"all", c"<0s", c"s78797a", c"", c"s")
	struct_test_row(t, c"all", c"<s", c"s00", c"00", c"s00")
	struct_test_row(t, c"all", c"<5p", c"s6869", c"0268690000", c"s6869")
	struct_test_row(t, c"all", c"<3p", c"s68656c6c6f", c"026865", c"s6865")
	struct_test_row(t, c"all", c"<1p", c"s7a", c"00", c"s")
	struct_test_row(t, c"all", c"<2HI4s", c"i1 i2 i3 s7370616d", c"01000200030000007370616d", c"i1 i2 i3 s7370616d")
	struct_test_row(t, c"all", c"<bxhx2xi", c"i1 i-2 i3", c"0100feff00000003000000", c"i1 i-2 i3")
	struct_test_row(t, c"all", c"<3B", c"i1 i2 i3", c"010203", c"i1 i2 i3")
	struct_test_row(t, c"all", c"<qQd", c"i-5 i7 d4004000000000000", c"fbffffffffffffff07000000000000000000000000000440", c"qfffffffffffffffb Q0000000000000007 d4004000000000000")
	struct_test_row(t, c"all", c"< i  h ", c"i10 i20", c"0a0000001400", c"i10 i20")
	struct_test_row(t, c"all", c"<0i", c"", c"", c"")
	struct_test_row(t, c"all", c"<", c"", c"", c"")
	struct_test_row(t, c"all", c"<?3c", c"?1 s61 s00 s63", c"01610063", c"?1 s61 s00 s63")
	struct_test_row(t, c"all", c">b", c"i-128", c"80", c"i-128")
	struct_test_row(t, c"all", c">b", c"i127", c"7f", c"i127")
	struct_test_row(t, c"all", c">B", c"i0", c"00", c"i0")
	struct_test_row(t, c"all", c">B", c"i255", c"ff", c"i255")
	struct_test_row(t, c"all", c">h", c"i-32768", c"8000", c"i-32768")
	struct_test_row(t, c"all", c">h", c"i12345", c"3039", c"i12345")
	struct_test_row(t, c"all", c">H", c"i65535", c"ffff", c"i65535")
	struct_test_row(t, c"all", c">i", c"i-2147483648", c"80000000", c"i-2147483648")
	struct_test_row(t, c"all", c">i", c"i2147483647", c"7fffffff", c"i2147483647")
	struct_test_row(t, c"all", c">I", c"uffffffff", c"ffffffff", c"uffffffff")
	struct_test_row(t, c"all", c">I", c"u80000000", c"80000000", c"u80000000")
	struct_test_row(t, c"all", c">l", c"i-7", c"fffffff9", c"i-7")
	struct_test_row(t, c"all", c">L", c"udeadbeef", c"deadbeef", c"udeadbeef")
	struct_test_row(t, c"all", c">q", c"i-1", c"ffffffffffffffff", c"qffffffffffffffff")
	struct_test_row(t, c"all", c">q", c"q8000000000000000", c"8000000000000000", c"q8000000000000000")
	struct_test_row(t, c"all", c">q", c"q7fffffffffffffff", c"7fffffffffffffff", c"q7fffffffffffffff")
	struct_test_row(t, c"all", c">q", c"q123456789abcdef0", c"123456789abcdef0", c"q123456789abcdef0")
	struct_test_row(t, c"all", c">Q", c"Qffffffffffffffff", c"ffffffffffffffff", c"Qffffffffffffffff")
	struct_test_row(t, c"all", c">Q", c"q0102030405060708", c"0102030405060708", c"Q0102030405060708")
	struct_test_row(t, c"all", c">Q", c"i5", c"0000000000000005", c"Q0000000000000005")
	struct_test_row(t, c"all", c">f", c"f3fc00000", c"3fc00000", c"f3fc00000")
	struct_test_row(t, c"all", c">f", c"f80000000", c"80000000", c"f80000000")
	struct_test_row(t, c"all", c">f", c"f7f800000", c"7f800000", c"f7f800000")
	struct_test_row(t, c"all", c">f", c"f00034447", c"00034447", c"f00034447")
	struct_test_row(t, c"all", c">d", c"d3ff8000000000000", c"3ff8000000000000", c"d3ff8000000000000")
	struct_test_row(t, c"all", c">d", c"dc000000000000000", c"c000000000000000", c"dc000000000000000")
	struct_test_row(t, c"all", c">d", c"d3fb999999999999a", c"3fb999999999999a", c"d3fb999999999999a")
	struct_test_row(t, c"all", c">d", c"dfff0000000000000", c"fff0000000000000", c"dfff0000000000000")
	struct_test_row(t, c"all", c">d", c"d0000000000000001", c"0000000000000001", c"d0000000000000001")
	struct_test_row(t, c"all", c">?", c"?1", c"01", c"?1")
	struct_test_row(t, c"all", c">?", c"?0", c"00", c"?0")
	struct_test_row(t, c"all", c">c", c"sff", c"ff", c"sff")
	struct_test_row(t, c"all", c">4s", c"s6162", c"61620000", c"s61620000")
	struct_test_row(t, c"all", c">2s", c"s61626364", c"6162", c"s6162")
	struct_test_row(t, c"all", c">0s", c"s78797a", c"", c"s")
	struct_test_row(t, c"all", c">s", c"s00", c"00", c"s00")
	struct_test_row(t, c"all", c">5p", c"s6869", c"0268690000", c"s6869")
	struct_test_row(t, c"all", c">3p", c"s68656c6c6f", c"026865", c"s6865")
	struct_test_row(t, c"all", c">1p", c"s7a", c"00", c"s")
	struct_test_row(t, c"all", c">2HI4s", c"i1 i2 i3 s7370616d", c"00010002000000037370616d", c"i1 i2 i3 s7370616d")
	struct_test_row(t, c"all", c">bxhx2xi", c"i1 i-2 i3", c"0100fffe00000000000003", c"i1 i-2 i3")
	struct_test_row(t, c"all", c">3B", c"i1 i2 i3", c"010203", c"i1 i2 i3")
	struct_test_row(t, c"all", c">qQd", c"i-5 i7 d4004000000000000", c"fffffffffffffffb00000000000000074004000000000000", c"qfffffffffffffffb Q0000000000000007 d4004000000000000")
	struct_test_row(t, c"all", c"> i  h ", c"i10 i20", c"0000000a0014", c"i10 i20")
	struct_test_row(t, c"all", c">0i", c"", c"", c"")
	struct_test_row(t, c"all", c">", c"", c"", c"")
	struct_test_row(t, c"all", c">?3c", c"?1 s61 s00 s63", c"01610063", c"?1 s61 s00 s63")
	struct_test_row(t, c"all", c"!b", c"i-128", c"80", c"i-128")
	struct_test_row(t, c"all", c"!b", c"i127", c"7f", c"i127")
	struct_test_row(t, c"all", c"!B", c"i0", c"00", c"i0")
	struct_test_row(t, c"all", c"!B", c"i255", c"ff", c"i255")
	struct_test_row(t, c"all", c"!h", c"i-32768", c"8000", c"i-32768")
	struct_test_row(t, c"all", c"!h", c"i12345", c"3039", c"i12345")
	struct_test_row(t, c"all", c"!H", c"i65535", c"ffff", c"i65535")
	struct_test_row(t, c"all", c"!i", c"i-2147483648", c"80000000", c"i-2147483648")
	struct_test_row(t, c"all", c"!i", c"i2147483647", c"7fffffff", c"i2147483647")
	struct_test_row(t, c"all", c"!I", c"uffffffff", c"ffffffff", c"uffffffff")
	struct_test_row(t, c"all", c"!I", c"u80000000", c"80000000", c"u80000000")
	struct_test_row(t, c"all", c"!l", c"i-7", c"fffffff9", c"i-7")
	struct_test_row(t, c"all", c"!L", c"udeadbeef", c"deadbeef", c"udeadbeef")
	struct_test_row(t, c"all", c"!q", c"i-1", c"ffffffffffffffff", c"qffffffffffffffff")
	struct_test_row(t, c"all", c"!q", c"q8000000000000000", c"8000000000000000", c"q8000000000000000")
	struct_test_row(t, c"all", c"!q", c"q7fffffffffffffff", c"7fffffffffffffff", c"q7fffffffffffffff")
	struct_test_row(t, c"all", c"!q", c"q123456789abcdef0", c"123456789abcdef0", c"q123456789abcdef0")
	struct_test_row(t, c"all", c"!Q", c"Qffffffffffffffff", c"ffffffffffffffff", c"Qffffffffffffffff")
	struct_test_row(t, c"all", c"!Q", c"q0102030405060708", c"0102030405060708", c"Q0102030405060708")
	struct_test_row(t, c"all", c"!Q", c"i5", c"0000000000000005", c"Q0000000000000005")
	struct_test_row(t, c"all", c"!f", c"f3fc00000", c"3fc00000", c"f3fc00000")
	struct_test_row(t, c"all", c"!f", c"f80000000", c"80000000", c"f80000000")
	struct_test_row(t, c"all", c"!f", c"f7f800000", c"7f800000", c"f7f800000")
	struct_test_row(t, c"all", c"!f", c"f00034447", c"00034447", c"f00034447")
	struct_test_row(t, c"all", c"!d", c"d3ff8000000000000", c"3ff8000000000000", c"d3ff8000000000000")
	struct_test_row(t, c"all", c"!d", c"dc000000000000000", c"c000000000000000", c"dc000000000000000")
	struct_test_row(t, c"all", c"!d", c"d3fb999999999999a", c"3fb999999999999a", c"d3fb999999999999a")
	struct_test_row(t, c"all", c"!d", c"dfff0000000000000", c"fff0000000000000", c"dfff0000000000000")
	struct_test_row(t, c"all", c"!d", c"d0000000000000001", c"0000000000000001", c"d0000000000000001")
	struct_test_row(t, c"all", c"!?", c"?1", c"01", c"?1")
	struct_test_row(t, c"all", c"!?", c"?0", c"00", c"?0")
	struct_test_row(t, c"all", c"!c", c"sff", c"ff", c"sff")
	struct_test_row(t, c"all", c"!4s", c"s6162", c"61620000", c"s61620000")
	struct_test_row(t, c"all", c"!2s", c"s61626364", c"6162", c"s6162")
	struct_test_row(t, c"all", c"!0s", c"s78797a", c"", c"s")
	struct_test_row(t, c"all", c"!s", c"s00", c"00", c"s00")
	struct_test_row(t, c"all", c"!5p", c"s6869", c"0268690000", c"s6869")
	struct_test_row(t, c"all", c"!3p", c"s68656c6c6f", c"026865", c"s6865")
	struct_test_row(t, c"all", c"!1p", c"s7a", c"00", c"s")
	struct_test_row(t, c"all", c"!2HI4s", c"i1 i2 i3 s7370616d", c"00010002000000037370616d", c"i1 i2 i3 s7370616d")
	struct_test_row(t, c"all", c"!bxhx2xi", c"i1 i-2 i3", c"0100fffe00000000000003", c"i1 i-2 i3")
	struct_test_row(t, c"all", c"!3B", c"i1 i2 i3", c"010203", c"i1 i2 i3")
	struct_test_row(t, c"all", c"!qQd", c"i-5 i7 d4004000000000000", c"fffffffffffffffb00000000000000074004000000000000", c"qfffffffffffffffb Q0000000000000007 d4004000000000000")
	struct_test_row(t, c"all", c"! i  h ", c"i10 i20", c"0000000a0014", c"i10 i20")
	struct_test_row(t, c"all", c"!0i", c"", c"", c"")
	struct_test_row(t, c"all", c"!", c"", c"", c"")
	struct_test_row(t, c"all", c"!?3c", c"?1 s61 s00 s63", c"01610063", c"?1 s61 s00 s63")
	struct_test_row(t, c"all", c"=b", c"i-128", c"80", c"i-128")
	struct_test_row(t, c"all", c"=b", c"i127", c"7f", c"i127")
	struct_test_row(t, c"all", c"=B", c"i0", c"00", c"i0")
	struct_test_row(t, c"all", c"=B", c"i255", c"ff", c"i255")
	struct_test_row(t, c"all", c"=h", c"i-32768", c"0080", c"i-32768")
	struct_test_row(t, c"all", c"=h", c"i12345", c"3930", c"i12345")
	struct_test_row(t, c"all", c"=H", c"i65535", c"ffff", c"i65535")
	struct_test_row(t, c"all", c"=i", c"i-2147483648", c"00000080", c"i-2147483648")
	struct_test_row(t, c"all", c"=i", c"i2147483647", c"ffffff7f", c"i2147483647")
	struct_test_row(t, c"all", c"=I", c"uffffffff", c"ffffffff", c"uffffffff")
	struct_test_row(t, c"all", c"=I", c"u80000000", c"00000080", c"u80000000")
	struct_test_row(t, c"all", c"=l", c"i-7", c"f9ffffff", c"i-7")
	struct_test_row(t, c"all", c"=L", c"udeadbeef", c"efbeadde", c"udeadbeef")
	struct_test_row(t, c"all", c"=q", c"i-1", c"ffffffffffffffff", c"qffffffffffffffff")
	struct_test_row(t, c"all", c"=q", c"q8000000000000000", c"0000000000000080", c"q8000000000000000")
	struct_test_row(t, c"all", c"=q", c"q7fffffffffffffff", c"ffffffffffffff7f", c"q7fffffffffffffff")
	struct_test_row(t, c"all", c"=q", c"q123456789abcdef0", c"f0debc9a78563412", c"q123456789abcdef0")
	struct_test_row(t, c"all", c"=Q", c"Qffffffffffffffff", c"ffffffffffffffff", c"Qffffffffffffffff")
	struct_test_row(t, c"all", c"=Q", c"q0102030405060708", c"0807060504030201", c"Q0102030405060708")
	struct_test_row(t, c"all", c"=Q", c"i5", c"0500000000000000", c"Q0000000000000005")
	struct_test_row(t, c"all", c"=f", c"f3fc00000", c"0000c03f", c"f3fc00000")
	struct_test_row(t, c"all", c"=f", c"f80000000", c"00000080", c"f80000000")
	struct_test_row(t, c"all", c"=f", c"f7f800000", c"0000807f", c"f7f800000")
	struct_test_row(t, c"all", c"=f", c"f00034447", c"47440300", c"f00034447")
	struct_test_row(t, c"all", c"=d", c"d3ff8000000000000", c"000000000000f83f", c"d3ff8000000000000")
	struct_test_row(t, c"all", c"=d", c"dc000000000000000", c"00000000000000c0", c"dc000000000000000")
	struct_test_row(t, c"all", c"=d", c"d3fb999999999999a", c"9a9999999999b93f", c"d3fb999999999999a")
	struct_test_row(t, c"all", c"=d", c"dfff0000000000000", c"000000000000f0ff", c"dfff0000000000000")
	struct_test_row(t, c"all", c"=d", c"d0000000000000001", c"0100000000000000", c"d0000000000000001")
	struct_test_row(t, c"all", c"=?", c"?1", c"01", c"?1")
	struct_test_row(t, c"all", c"=?", c"?0", c"00", c"?0")
	struct_test_row(t, c"all", c"=c", c"sff", c"ff", c"sff")
	struct_test_row(t, c"all", c"=4s", c"s6162", c"61620000", c"s61620000")
	struct_test_row(t, c"all", c"=2s", c"s61626364", c"6162", c"s6162")
	struct_test_row(t, c"all", c"=0s", c"s78797a", c"", c"s")
	struct_test_row(t, c"all", c"=s", c"s00", c"00", c"s00")
	struct_test_row(t, c"all", c"=5p", c"s6869", c"0268690000", c"s6869")
	struct_test_row(t, c"all", c"=3p", c"s68656c6c6f", c"026865", c"s6865")
	struct_test_row(t, c"all", c"=1p", c"s7a", c"00", c"s")
	struct_test_row(t, c"all", c"=2HI4s", c"i1 i2 i3 s7370616d", c"01000200030000007370616d", c"i1 i2 i3 s7370616d")
	struct_test_row(t, c"all", c"=bxhx2xi", c"i1 i-2 i3", c"0100feff00000003000000", c"i1 i-2 i3")
	struct_test_row(t, c"all", c"=3B", c"i1 i2 i3", c"010203", c"i1 i2 i3")
	struct_test_row(t, c"all", c"=qQd", c"i-5 i7 d4004000000000000", c"fbffffffffffffff07000000000000000000000000000440", c"qfffffffffffffffb Q0000000000000007 d4004000000000000")
	struct_test_row(t, c"all", c"= i  h ", c"i10 i20", c"0a0000001400", c"i10 i20")
	struct_test_row(t, c"all", c"=0i", c"", c"", c"")
	struct_test_row(t, c"all", c"=", c"", c"", c"")
	struct_test_row(t, c"all", c"=?3c", c"?1 s61 s00 s63", c"01610063", c"?1 s61 s00 s63")
	struct_test_row(t, c"all", c"<f", c"f40400000", c"00004040", c"f40400000")
	struct_test_row(t, c"all", c">d", c"dc12e848000000000", c"c12e848000000000", c"dc12e848000000000")
	struct_test_row(t, c"all", c"<d", c"d4170000010000000", c"0000001000007041", c"d4170000010000000")
	struct_test_row(t, c"all", c"<d", c"dc1e0000000000000", c"000000000000e0c1", c"dc1e0000000000000")
	struct_test_row(t, c"all", c"<d", c"w3dcccccd", c"000000a09999b93f", c"d3fb99999a0000000")
	struct_test_row(t, c"all", c">d", c"w80000001", c"b6a0000000000000", c"db6a0000000000000")
	struct_test_row(t, c"all", c"<d", c"w7fc00000", c"000000000000f87f", c"d7ff8000000000000")
	struct_test_row(t, c"all", c"<d", c"wff800000", c"000000000000f0ff", c"dfff0000000000000")
	struct_test_row(t, c"all", c"<d", c"w7149f2ca", c"00000040593e2946", c"d46293e5940000000")
	struct_test_row(t, c"all", c"<q", c"q0000000000000005", c"0500000000000000", c"q0000000000000005")
	struct_test_row(t, c"all", c">Q", c"Q00000000ffffffff", c"00000000ffffffff", c"Q00000000ffffffff")
	struct_test_row(t, c"all", c"<i", c"qffffffffffffff85", c"85ffffff", c"i-123")
	struct_test_row(t, c"all", c"<B", c"Q00000000000000ff", c"ff", c"i255")
	struct_test_row(t, c"all", c"<H", c"i1", c"0100", c"i1")
	struct_test_row(t, c"all", c"@bhi", c"i1 i2 i3", c"0100020003000000", c"i1 i2 i3")
	struct_test_row(t, c"all", c"bi", c"i-1 i-2", c"ff000000feffffff", c"i-1 i-2")
	struct_test_row(t, c"all", c"@cH", c"s78 i7", c"78000700", c"s78 i7")
	struct_test_row(t, c"all", c"@?f", c"?1 f40000000", c"0100000000000040", c"?1 f40000000")
	struct_test_row(t, c"all", c"@3s i", c"s6162 i9", c"6162000009000000", c"s616200 i9")
	struct_test_row(t, c"all", c"@b0i", c"i5", c"05000000", c"i5")
	struct_test_row(t, c"all", c"@hbbI", c"i1 i2 i3 i4", c"0100020304000000", c"i1 i2 i3 i4")
	struct_test_row(t, c"all", c"@5pH", c"s616263 i1", c"0361626300000100", c"s616263 i1")
	struct_test_row(t, c"all", c"@xh", c"i3", c"00000300", c"i3")
	struct_test_row(t, c"64", c"@bq", c"i1 i-2", c"0100000000000000feffffffffffffff", c"i1 qfffffffffffffffe")
	struct_test_row(t, c"64", c"@bl", c"i1 i2", c"01000000000000000200000000000000", c"i1 q0000000000000002")
	struct_test_row(t, c"64", c"@bL", c"i1 Qffffffffffffffff", c"0100000000000000ffffffffffffffff", c"i1 Qffffffffffffffff")
	struct_test_row(t, c"64", c"@id", c"i1 d4004000000000000", c"01000000000000000000000000000440", c"i1 d4004000000000000")
	struct_test_row(t, c"64", c"@b0q", c"i1", c"0100000000000000", c"i1")
	struct_test_row(t, c"64", c"@hn", c"i3 i-4", c"0300000000000000fcffffffffffffff", c"i3 qfffffffffffffffc")
	struct_test_row(t, c"64", c"@bN", c"i1 i2", c"01000000000000000200000000000000", c"i1 Q0000000000000002")
	struct_test_row(t, c"64", c"@bP", c"i1 i4096", c"01000000000000000010000000000000", c"i1 Q0000000000001000")
	struct_test_row(t, c"64", c"@cQ?d", c"s7a i9 ?1 dbfe0000000000000", c"7a0000000000000009000000000000000100000000000000000000000000e0bf", c"s7a Q0000000000000009 ?1 dbfe0000000000000")
	struct_test_row(t, c"64", c"l", c"i-3", c"fdffffffffffffff", c"qfffffffffffffffd")
	struct_test_row(t, c"32", c"@bq", c"i1 i-2", c"01000000feffffffffffffff", c"i1 qfffffffffffffffe")
	struct_test_row(t, c"32", c"@bl", c"i1 i2", c"0100000002000000", c"i1 i2")
	struct_test_row(t, c"32", c"@bL", c"i1 uffffffff", c"01000000ffffffff", c"i1 uffffffff")
	struct_test_row(t, c"32", c"@id", c"i1 d4004000000000000", c"010000000000000000000440", c"i1 d4004000000000000")
	struct_test_row(t, c"32", c"@b0q", c"i1", c"01000000", c"i1")
	struct_test_row(t, c"32", c"@hn", c"i3 i-4", c"03000000fcffffff", c"i3 i-4")
	struct_test_row(t, c"32", c"@bN", c"i1 i2", c"0100000002000000", c"i1 i2")
	struct_test_row(t, c"32", c"@bP", c"i1 i4096", c"0100000000100000", c"i1 i4096")
	struct_test_row(t, c"32", c"@cQ?d", c"s7a i9 ?1 dbfe0000000000000", c"7a000000090000000000000001000000000000000000e0bf", c"s7a Q0000000000000009 ?1 dbfe0000000000000")
	struct_test_row(t, c"32", c"l", c"i-3", c"fdffffff", c"i-3")


void struct_test_calcsize_rows(list[char*] formats, list[int] sizes):
	formats.push(c"<")
	sizes.push(0)
	formats.push(c"<b")
	sizes.push(1)
	formats.push(c"<2HI4s")
	sizes.push(12)
	formats.push(c">qQd")
	sizes.push(24)
	formats.push(c"!10x")
	sizes.push(10)
	formats.push(c"=0s")
	sizes.push(0)
	formats.push(c"<3p")
	sizes.push(3)
	formats.push(c"< 2i")
	sizes.push(8)
	formats.push(c">5?")
	sizes.push(5)
	formats.push(c"<bhilqfd")
	sizes.push(31)
	formats.push(c"@bhi")
	sizes.push(8)
	formats.push(c"@b0i")
	sizes.push(4)
	formats.push(c"@hbbI")
	sizes.push(8)
	formats.push(c"xh")
	sizes.push(4)
	formats.push(c"<z")
	sizes.push(-1)
	formats.push(c"<n")
	sizes.push(-1)
	formats.push(c">N")
	sizes.push(-1)
	formats.push(c"!P")
	sizes.push(-1)
	formats.push(c"<2")
	sizes.push(-1)
	formats.push(c"<3 i")
	sizes.push(-1)
	formats.push(c"<i@")
	sizes.push(-1)
	formats.push(c"<-1i")
	sizes.push(-1)
	formats.push(c"<2 ")
	sizes.push(-1)


void struct_test_error_rows(list[char*] t):
	t.push(c"<b")
	t.push(c"i128")
	t.push(c"<b")
	t.push(c"i-129")
	t.push(c"<B")
	t.push(c"i-1")
	t.push(c"<B")
	t.push(c"i256")
	t.push(c"<h")
	t.push(c"i32768")
	t.push(c"<H")
	t.push(c"i-1")
	t.push(c"<H")
	t.push(c"i65536")
	t.push(c"<Q")
	t.push(c"i-1")
	t.push(c"<Q")
	t.push(c"qffffffffffffffff")
	t.push(c"<q")
	t.push(c"Q8000000000000000")
	t.push(c"<i")
	t.push(c"Q0000000100000000")
	t.push(c"<I")
	t.push(c"q0000000100000000")
	t.push(c"<I")
	t.push(c"qffffffffffffffff")
	t.push(c"<h")
	t.push(c"q0000000000008000")
	t.push(c"<h")
	t.push(c"qffffffffffff7fff")
	t.push(c"<b")
	t.push(c"f3f800000")
	t.push(c"<c")
	t.push(c"sabcd")
	t.push(c"<c")
	t.push(c"s")
	t.push(c"<c")
	t.push(c"i1")
	t.push(c"<s")
	t.push(c"i1")
	t.push(c"<p")
	t.push(c"f00000000")
	t.push(c"<f")
	t.push(c"sab")
	t.push(c"<f")
	t.push(c"d3ff0000000000000")
	t.push(c"<d")
	t.push(c"sab")
	t.push(c"<2i")
	t.push(c"i1")
	t.push(c"<i")
	t.push(c"i1 i2")
	t.push(c"<")
	t.push(c"i1")
	t.push(c"<z")
	t.push(c"i1")
	t.push(c"<d")
	t.push(c"q0020000000000001")
