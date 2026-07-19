# wbuild: name=net_asn1_test x64
# Tests for libs/standard/net/asn1.w: strict DER header handling (bounds,
# minimal lengths, rejected indefinite/oversized forms) and the typed
# helpers x509.w builds on. All inputs are hand-built byte buffers.
import lib.testing
import libs.standard.net.asn1


# Build a reader over the first n bytes of buf.
void ta_init(asn1* r, char* buf, int n):
	asn1_init(r, buf, 0, n)


void test_short_form_header():
	char* b = malloc(3)
	b[0] = 2      # INTEGER
	b[1] = 1
	b[2] = 5
	asn1 r
	ta_init(&r, b, 3)
	int tag = 0
	int start = 0
	int len = 0
	assert_equal(1, asn1_next(&r, &tag, &start, &len))
	assert_equal(ASN1_INTEGER(), tag)
	assert_equal(2, start)
	assert_equal(1, len)
	assert_equal(1, asn1_done(&r))
	free(b)


void test_long_form_minimal():
	# 0x30 0x81 0x80 + 128 content bytes: minimal one-byte long form.
	char* b = malloc(131)
	b[0] = 48
	b[1] = 129    # 0x81
	b[2] = 128    # length 128
	int i = 0
	while (i < 128):
		b[3 + i] = 0
		i = i + 1
	asn1 r
	ta_init(&r, b, 131)
	int tag = 0
	int start = 0
	int len = 0
	assert_equal(1, asn1_next(&r, &tag, &start, &len))
	assert_equal(48, tag)
	assert_equal(128, len)
	assert_equal(1, asn1_done(&r))
	free(b)


void test_long_form_non_minimal_rejected():
	# 0x81 0x7f: long form used for a length below 128 -> reject.
	char* b = malloc(130)
	b[0] = 48
	b[1] = 129
	b[2] = 127
	int i = 0
	while (i < 127):
		b[3 + i] = 0
		i = i + 1
	asn1 r
	ta_init(&r, b, 130)
	int tag = 0
	int start = 0
	int len = 0
	assert_equal(0, asn1_next(&r, &tag, &start, &len))
	free(b)


void test_indefinite_length_rejected():
	char* b = malloc(4)
	b[0] = 48
	b[1] = 128    # 0x80: indefinite
	b[2] = 0
	b[3] = 0
	asn1 r
	ta_init(&r, b, 4)
	int tag = 0
	int start = 0
	int len = 0
	assert_equal(0, asn1_next(&r, &tag, &start, &len))
	free(b)


void test_truncated_content_rejected():
	# Claims 5 content bytes, only 3 present.
	char* b = malloc(5)
	b[0] = 4
	b[1] = 5
	b[2] = 1
	b[3] = 2
	b[4] = 3
	asn1 r
	ta_init(&r, b, 5)
	int tag = 0
	int start = 0
	int len = 0
	assert_equal(0, asn1_next(&r, &tag, &start, &len))
	# Zero-length window and lone tag byte also fail cleanly.
	ta_init(&r, b, 0)
	assert_equal(0, asn1_next(&r, &tag, &start, &len))
	ta_init(&r, b, 1)
	assert_equal(0, asn1_next(&r, &tag, &start, &len))
	free(b)


void test_multibyte_tag_rejected():
	char* b = malloc(3)
	b[0] = 31     # 0x1f: low tag bits all set = multi-byte tag follows
	b[1] = 1
	b[2] = 0
	asn1 r
	ta_init(&r, b, 3)
	int tag = 0
	int start = 0
	int len = 0
	assert_equal(0, asn1_next(&r, &tag, &start, &len))
	free(b)


void test_oversized_length_rejected():
	# 5 length bytes is beyond the 4-byte cap.
	char* b = malloc(8)
	b[0] = 48
	b[1] = 133    # 0x85
	b[2] = 1
	b[3] = 0
	b[4] = 0
	b[5] = 0
	b[6] = 0
	b[7] = 0
	asn1 r
	ta_init(&r, b, 8)
	int tag = 0
	int start = 0
	int len = 0
	assert_equal(0, asn1_next(&r, &tag, &start, &len))
	# A 4-byte length with the top bit set would overflow a 32-bit int.
	b[1] = 132    # 0x84
	b[2] = 128    # 0x80......
	ta_init(&r, b, 8)
	assert_equal(0, asn1_next(&r, &tag, &start, &len))
	# Leading zero length byte is non-minimal.
	b[1] = 130    # 0x82
	b[2] = 0
	b[3] = 200
	ta_init(&r, b, 8)
	assert_equal(0, asn1_next(&r, &tag, &start, &len))
	free(b)


void test_expect_and_skip():
	# SEQUENCE { INTEGER 7, BOOLEAN true }
	char* b = malloc(10)
	b[0] = 48
	b[1] = 6
	b[2] = 2
	b[3] = 1
	b[4] = 7
	b[5] = 1
	b[6] = 1
	b[7] = 255
	asn1 r
	ta_init(&r, b, 8)
	int s = 0
	int l = 0
	assert_equal(1, asn1_expect(&r, ASN1_SEQUENCE(), &s, &l))
	assert_equal(6, l)
	assert_equal(1, asn1_done(&r))
	asn1 inner
	asn1_init(&inner, b, s, s + l)
	assert_equal(ASN1_INTEGER(), asn1_peek(&inner))
	assert_equal(1, asn1_skip(&inner))
	int v = 0
	assert_equal(1, asn1_read_boolean(&inner, &v))
	assert_equal(1, v)
	assert_equal(1, asn1_done(&inner))
	# Wrong expected tag fails.
	ta_init(&r, b, 8)
	assert_equal(0, asn1_expect(&r, ASN1_SET(), &s, &l))
	free(b)


void test_trailing_garbage_detected():
	char* b = malloc(4)
	b[0] = 2
	b[1] = 1
	b[2] = 5
	b[3] = 0      # stray byte after the element
	asn1 r
	ta_init(&r, b, 4)
	int tag = 0
	int start = 0
	int len = 0
	assert_equal(1, asn1_next(&r, &tag, &start, &len))
	assert_equal(0, asn1_done(&r))
	free(b)


void test_integer_minimality():
	char* b = malloc(8)
	# 02 02 00 01: redundant leading zero -> reject.
	b[0] = 2
	b[1] = 2
	b[2] = 0
	b[3] = 1
	asn1 r
	ta_init(&r, b, 4)
	int s = 0
	int l = 0
	assert_equal(0, asn1_read_integer(&r, &s, &l))
	# 02 02 00 80: leading zero clears the sign bit -> accept.
	b[3] = 128
	ta_init(&r, b, 4)
	assert_equal(1, asn1_read_integer(&r, &s, &l))
	assert_equal(2, l)
	# 02 02 ff 00 (-256): minimal negative -> accepted by read_integer.
	b[2] = 255
	b[3] = 0
	ta_init(&r, b, 4)
	assert_equal(1, asn1_read_integer(&r, &s, &l))
	# 02 02 ff 80: redundant leading ff (0x80 alone encodes -128) -> reject.
	b[3] = 128
	ta_init(&r, b, 4)
	assert_equal(0, asn1_read_integer(&r, &s, &l))
	# 02 00: empty integer -> reject.
	b[1] = 0
	ta_init(&r, b, 2)
	assert_equal(0, asn1_read_integer(&r, &s, &l))
	free(b)


void test_small_int():
	char* b = malloc(10)
	b[0] = 2
	b[1] = 1
	b[2] = 0
	asn1 r
	ta_init(&r, b, 3)
	int v = -1
	assert_equal(1, asn1_read_small_int(&r, &v))
	assert_equal(0, v)
	# Two-byte value 0x0102.
	b[1] = 2
	b[2] = 1
	b[3] = 2
	ta_init(&r, b, 4)
	assert_equal(1, asn1_read_small_int(&r, &v))
	assert_equal(258, v)
	# Negative rejected.
	b[1] = 1
	b[2] = 255
	ta_init(&r, b, 3)
	assert_equal(0, asn1_read_small_int(&r, &v))
	# 5 magnitude bytes never fit.
	b[1] = 5
	b[2] = 1
	b[3] = 0
	b[4] = 0
	b[5] = 0
	b[6] = 0
	ta_init(&r, b, 7)
	assert_equal(0, asn1_read_small_int(&r, &v))
	# 4 bytes with the top bit set would go negative.
	b[1] = 4
	b[2] = 128
	ta_init(&r, b, 6)
	assert_equal(0, asn1_read_small_int(&r, &v))
	free(b)


void test_positive_integer():
	char* b = malloc(8)
	# 00 80 strips to the single byte 0x80.
	b[0] = 2
	b[1] = 2
	b[2] = 0
	b[3] = 128
	asn1 r
	ta_init(&r, b, 4)
	int s = 0
	int l = 0
	assert_equal(1, asn1_read_positive_integer(&r, &s, &l))
	assert_equal(1, l)
	assert_equal(3, s)
	# Zero is not positive.
	b[1] = 1
	b[2] = 0
	ta_init(&r, b, 3)
	assert_equal(0, asn1_read_positive_integer(&r, &s, &l))
	# Negative rejected.
	b[2] = 254
	ta_init(&r, b, 3)
	assert_equal(0, asn1_read_positive_integer(&r, &s, &l))
	free(b)


void test_boolean_strictness():
	char* b = malloc(4)
	b[0] = 1
	b[1] = 1
	b[2] = 1      # neither 0x00 nor 0xff
	asn1 r
	ta_init(&r, b, 3)
	int v = 0
	assert_equal(0, asn1_read_boolean(&r, &v))
	b[2] = 0
	ta_init(&r, b, 3)
	assert_equal(1, asn1_read_boolean(&r, &v))
	assert_equal(0, v)
	# Two content bytes rejected.
	b[1] = 2
	b[2] = 255
	b[3] = 255
	ta_init(&r, b, 4)
	assert_equal(0, asn1_read_boolean(&r, &v))
	free(b)


void test_bitstring_bytes():
	char* b = malloc(5)
	b[0] = 3
	b[1] = 2
	b[2] = 0      # zero unused bits
	b[3] = 170
	asn1 r
	ta_init(&r, b, 4)
	int s = 0
	int l = 0
	assert_equal(1, asn1_read_bitstring_bytes(&r, &s, &l))
	assert_equal(3, s)
	assert_equal(1, l)
	assert_equal(170, b[s] & 255)
	# Nonzero unused-bits count rejected (keys/signatures are byte-aligned).
	b[2] = 4
	ta_init(&r, b, 4)
	assert_equal(0, asn1_read_bitstring_bytes(&r, &s, &l))
	# Empty bit string (no unused-bits byte) rejected.
	b[1] = 0
	ta_init(&r, b, 2)
	assert_equal(0, asn1_read_bitstring_bytes(&r, &s, &l))
	free(b)


void test_bytes_equal():
	char* b = malloc(4)
	b[0] = 85
	b[1] = 29
	b[2] = 17
	assert_equal(1, asn1_bytes_equal(b, 0, 3, c"\x55\x1d\x11", 3))
	assert_equal(0, asn1_bytes_equal(b, 0, 3, c"\x55\x1d\x13", 3))
	assert_equal(0, asn1_bytes_equal(b, 0, 2, c"\x55\x1d\x11", 3))
	free(b)
