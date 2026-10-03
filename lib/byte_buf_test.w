# wbuild: x64
# lib/byte_buf.w: borrowed views, owned buffers (limits, take/release),
# and the checked reader/writer cursors (fixed width, 64-bit, spans,
# length prefixes, varints, sticky errors, malformed input).
import lib.testing
import lib.byte_buf


int is64():
	if (sizeof(int) == 8): return 1
	return 0


void expect_bytes(byte_buf* b, char* want, int length):
	assert_equal(length, b.length)
	assert_bytes_equal(want, b.data, length)


void test_view_slice_bounds():
	byte_view v = byte_view_of(c"hello\x00world", 11)
	assert_equal(11, v.length)
	byte_view s
	assert_equal(1, byte_view_slice(v, 4, 3, &s))
	assert_equal(3, s.length)
	assert_equal('o', s.data[0])
	assert_equal(0, s.data[1])
	assert_equal(1, byte_view_slice(v, 11, 0, &s))
	assert_equal(0, byte_view_slice(v, 9, 3, &s))
	assert_equal(0, s.length)
	assert_equal(0, byte_view_slice(v, 0 - 1, 1, &s))
	assert_equal(0, byte_view_slice(v, 1, 0 - 1, &s))
	assert_equal(0, byte_view_slice(v, 12, 0, &s))
	assert_equal(0, byte_view_slice(v, 1, checked_int_max(), &s))
	assert_equal(0, byte_view_of(c"x", 0 - 5).length)
	char* copy = byte_view_clone(v)
	assert_bytes_equal(c"hello\x00world", copy, 11)
	free(copy)


void test_view_compare():
	byte_view a = byte_view_of(c"a\x00\xff", 3)
	byte_view b = byte_view_of(c"a\x00\x01", 3)
	assert_equal(1, byte_view_compare(a, b))
	assert_equal(0 - 1, byte_view_compare(b, a))
	assert_equal(1, byte_view_equal(a, a))
	assert_equal(0, byte_view_equal(a, b))


void test_buf_append_grow_take():
	byte_buf b
	byte_buf_init(&b, 0)
	assert_equal(0, b.length)
	for i in range(100):
		assert_equal(BYTES_OK, byte_buf_append_u8(&b, i))
	assert_equal(100, b.length)
	assert1(b.capacity >= 100)
	assert_equal(BYTES_OK, byte_buf_append(&b, c"\x00\x01", 2))
	byte_view v = byte_buf_view(&b)
	assert_equal(102, v.length)
	assert_equal(99, v.data[99])
	assert_equal(0, v.data[100])
	int n = 0
	char* owned = byte_buf_take(&b, &n)
	assert_equal(102, n)
	assert_equal(0, b.length)
	assert_equal(0, b.capacity)
	assert1(b.data == 0)
	assert_equal(42, owned[42])
	free(owned)
	# The buffer is reusable after take.
	assert_equal(BYTES_OK, byte_buf_append(&b, c"xyz", 3))
	expect_bytes(&b, c"xyz", 3)
	byte_buf_clear(&b)
	assert_equal(0, b.length)
	assert1(b.capacity > 0)
	byte_buf_release(&b)
	assert_equal(0, b.capacity)
	assert1(b.data == 0)
	# take on a never-reserved buffer returns null and 0.
	char* none = byte_buf_take(&b, &n)
	assert1(none == 0)
	assert_equal(0, n)


void test_buf_limits():
	byte_buf* b = byte_buf_new(10)
	assert_equal(BYTES_OK, byte_buf_append(b, c"0123456789", 10))
	assert_equal(10, b.capacity)  # growth clamps to the cap
	assert_equal(BYTES_TOO_LARGE, byte_buf_append_u8(b, 1))
	assert_equal(10, b.length)  # unchanged on failure
	assert_equal(BYTES_INVALID, byte_buf_reserve(b, 0 - 1))
	assert_equal(BYTES_INVALID, byte_buf_append(b, c"x", 0 - 1))
	byte_buf_clear(b)
	assert_equal(BYTES_TOO_LARGE, byte_buf_reserve(b, 11))
	assert_equal(BYTES_OK, byte_buf_reserve(b, 10))
	byte_buf_free(b)
	# length + extra overflowing the word is rejected before any malloc.
	byte_buf u
	byte_buf_init(&u, 0)
	assert_equal(BYTES_OK, byte_buf_append(&u, c"ab", 2))
	assert_equal(BYTES_TOO_LARGE, byte_buf_reserve(&u, checked_int_max()))
	assert_equal(BYTES_TOO_LARGE, byte_buf_reserve(&u, checked_int_max() - 1))
	assert_equal(2, u.length)
	byte_buf_release(&u)


void test_writer_reader_fixed_width_round_trip():
	byte_buf b
	byte_buf_init(&b, 0)
	byte_writer w
	byte_writer_init(&w, &b)
	byte_writer_u8(&w, 0xab)
	byte_writer_u16be(&w, 0x1234)
	byte_writer_u16le(&w, 0x1234)
	byte_writer_u32be(&w, cast(int, 0xdeadbeef))
	byte_writer_u32le(&w, 0x01020304)
	byte_writer_u64be_parts(&w, cast(int, 0x80000001), 0x02030405)
	byte_writer_u64le(&w, 0x7fffffff)
	byte_writer_bytes(&w, c"a\x00b", 3)
	assert_equal(BYTES_OK, byte_writer_status(&w))
	assert_equal(1 + 2 + 2 + 4 + 4 + 8 + 8 + 3, b.length)
	assert_bytes_equal(c"\xab\x12\x34\x34\x12\xde\xad\xbe\xef\x04\x03\x02\x01", b.data, 13)
	assert_bytes_equal(c"\x80\x00\x00\x01\x02\x03\x04\x05", &b.data[13], 8)
	assert_bytes_equal(c"\xff\xff\xff\x7f\x00\x00\x00\x00a\x00b", &b.data[21], 11)

	byte_reader r
	byte_reader_init(&r, b.data, b.length)
	assert_equal(0xab, byte_reader_u8(&r))
	assert_equal(0x1234, byte_reader_u16be(&r))
	assert_equal(0x1234, byte_reader_u16le(&r))
	assert_equal(bytes_mask32() & cast(int, 0xdeadbeef), byte_reader_u32be(&r))
	assert_equal(0x01020304, byte_reader_u32le(&r))
	int hi = 0
	int lo = 0
	assert_equal(1, byte_reader_u64be_parts(&r, &hi, &lo))
	assert_equal(bytes_mask32() & cast(int, 0x80000001), hi)
	assert_equal(0x02030405, lo)
	assert_equal(0x7fffffff, byte_reader_u64le(&r))
	byte_view tail
	assert_equal(1, byte_reader_bytes(&r, 3, &tail))
	assert_equal(1, byte_view_equal(tail, byte_view_of(c"a\x00b", 3)))
	assert_equal(1, byte_reader_at_end(&r))
	assert_equal(BYTES_OK, byte_reader_status(&r))
	byte_buf_release(&b)


void test_reader_u64_word_size():
	byte_reader r
	byte_reader_init(&r, c"\x00\x00\x00\x01\x00\x00\x00\x02", 8)
	int v = byte_reader_u64be(&r)
	if (is64()):
		assert_equal(BYTES_OK, byte_reader_status(&r))
		assert_equal((1 << 32) | 2, v)
	else:
		# Never truncated to 2: the read fails and does not advance.
		assert_equal(0, v)
		assert_equal(BYTES_OVERFLOW, byte_reader_status(&r))
		assert_equal(0, r.pos)
	byte_reader_init(&r, c"\x02\x00\x00\x00\x00\x00\x00\x00", 8)
	assert_equal(2, byte_reader_u64le(&r))


void test_reader_truncation_is_sticky():
	byte_reader r
	byte_reader_init(&r, c"\x01\x02\x03", 3)
	assert_equal(0x0102, byte_reader_u16be(&r))
	assert_equal(0, byte_reader_u32be(&r))  # needs 4, has 1
	assert_equal(BYTES_TRUNCATED, byte_reader_status(&r))
	assert_equal(2, r.pos)  # the failing read did not advance
	# Later reads that would fit still return 0 and keep the first error.
	assert_equal(0, byte_reader_u8(&r))
	assert_equal(BYTES_TRUNCATED, byte_reader_status(&r))
	byte_view v
	assert_equal(0, byte_reader_bytes(&r, 1, &v))
	assert_equal(0, v.length)
	# Negative counts are invalid, not huge.
	byte_reader_init(&r, c"abc", 3)
	assert_equal(0, byte_reader_skip(&r, 0 - 1))
	assert_equal(BYTES_INVALID, byte_reader_status(&r))
	byte_reader_init(&r, c"abc", 0 - 1)
	assert_equal(BYTES_INVALID, byte_reader_status(&r))
	assert_equal(0, byte_reader_remaining(&r))
	# Empty input.
	byte_reader_init(&r, c"", 0)
	assert_equal(1, byte_reader_at_end(&r))
	assert_equal(0, byte_reader_u8(&r))
	assert_equal(BYTES_TRUNCATED, byte_reader_status(&r))


void test_reader_copy_and_skip():
	byte_reader r
	byte_reader_init(&r, c"abcdef", 6)
	assert_equal(1, byte_reader_skip(&r, 2))
	char* dst = malloc(4)
	assert_equal(1, byte_reader_copy(&r, dst, 4))
	assert_bytes_equal(c"cdef", dst, 4)
	assert_equal(0, byte_reader_copy(&r, dst, 1))
	free(dst)


void expect_varint(int v, char* want, int length):
	byte_buf b
	byte_buf_init(&b, 0)
	byte_writer w
	byte_writer_init(&w, &b)
	assert_equal(1, byte_writer_varint(&w, v))
	expect_bytes(&b, want, length)
	assert_equal(length, bytes_varint_size(v))
	byte_reader r
	byte_reader_init(&r, b.data, b.length)
	assert_equal(v, byte_reader_varint(&r))
	assert_equal(BYTES_OK, byte_reader_status(&r))
	assert_equal(1, byte_reader_at_end(&r))
	byte_buf_release(&b)


void test_varint_vectors():
	expect_varint(0, c"\x00", 1)
	expect_varint(1, c"\x01", 1)
	expect_varint(127, c"\x7f", 1)
	expect_varint(128, c"\x80\x01", 2)
	expect_varint(300, c"\xac\x02", 2)
	expect_varint(0x7fffffff, c"\xff\xff\xff\xff\x07", 5)
	if (is64()):
		expect_varint(1 << 32, c"\x80\x80\x80\x80\x10", 5)
		expect_varint(0 - 1, c"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", 10)
	else:
		# The 32-bit word -1 is the u32 0xffffffff, zero-extended.
		expect_varint(0 - 1, c"\xff\xff\xff\xff\x0f", 5)


void test_varint_parts_full_range():
	byte_buf b
	byte_buf_init(&b, 0)
	byte_writer w
	byte_writer_init(&w, &b)
	int m = bytes_mask32()
	assert_equal(1, byte_writer_varint_parts(&w, m, m))
	expect_bytes(&b, c"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", 10)
	byte_reader r
	byte_reader_init(&r, b.data, b.length)
	int hi = 0
	int lo = 0
	assert_equal(1, byte_reader_varint_parts(&r, &hi, &lo))
	assert_equal(m, hi)
	assert_equal(m, lo)
	# The same bytes overflow the native word on a 32-bit target only.
	byte_reader_init(&r, b.data, b.length)
	int v = byte_reader_varint(&r)
	if (is64()):
		assert_equal(0 - 1, v)
		assert_equal(BYTES_OK, byte_reader_status(&r))
	else:
		assert_equal(BYTES_OVERFLOW, byte_reader_status(&r))
		assert_equal(0, r.pos)
	byte_buf_release(&b)


int varint_status(char* data, int length):
	byte_reader r
	byte_reader_init(&r, data, length)
	int hi = 0
	int lo = 0
	byte_reader_varint_parts(&r, &hi, &lo)
	return byte_reader_status(&r)


void test_varint_malformed():
	assert_equal(BYTES_TRUNCATED, varint_status(c"", 0))
	assert_equal(BYTES_TRUNCATED, varint_status(c"\x80", 1))
	assert_equal(BYTES_TRUNCATED, varint_status(c"\xff\xff\xff", 3))
	# Non-minimal (overlong) encodings of small values.
	assert_equal(BYTES_MALFORMED, varint_status(c"\x80\x00", 2))
	assert_equal(BYTES_MALFORMED, varint_status(c"\x81\x80\x00", 3))
	# More than 10 bytes.
	assert_equal(BYTES_MALFORMED, varint_status(c"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01", 11))
	# 10th byte carrying bits beyond 2^64.
	assert_equal(BYTES_OVERFLOW, varint_status(c"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02", 10))
	assert_equal(BYTES_OVERFLOW, varint_status(c"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x7f", 10))
	# 10 bytes ending in 01 is the largest legal value.
	assert_equal(BYTES_OK, varint_status(c"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01", 10))


void test_prefixed_spans():
	byte_buf b
	byte_buf_init(&b, 0)
	byte_writer w
	byte_writer_init(&w, &b)
	assert_equal(1, byte_writer_prefixed(&w, BYTES_PREFIX_U8, c"a\x00", 2))
	assert_equal(1, byte_writer_prefixed(&w, BYTES_PREFIX_U16BE, c"bcd", 3))
	assert_equal(1, byte_writer_prefixed(&w, BYTES_PREFIX_U32LE, c"", 0))
	assert_equal(1, byte_writer_prefixed(&w, BYTES_PREFIX_VARINT, c"xyz", 3))
	expect_bytes(&b, c"\x02a\x00\x00\x03bcd\x00\x00\x00\x00\x03xyz", 16)

	byte_reader r
	byte_reader_init(&r, b.data, b.length)
	byte_view v
	assert_equal(1, byte_reader_prefixed(&r, BYTES_PREFIX_U8, 16, &v))
	assert_equal(1, byte_view_equal(v, byte_view_of(c"a\x00", 2)))
	assert_equal(1, byte_reader_prefixed(&r, BYTES_PREFIX_U16BE, 3, &v))
	assert_equal(1, byte_view_equal(v, byte_view_of(c"bcd", 3)))
	assert_equal(1, byte_reader_prefixed(&r, BYTES_PREFIX_U32LE, 0, &v))
	assert_equal(0, v.length)
	# Caller max smaller than the declared length.
	int at = r.pos
	assert_equal(0, byte_reader_prefixed(&r, BYTES_PREFIX_VARINT, 2, &v))
	assert_equal(BYTES_TOO_LARGE, byte_reader_status(&r))
	assert_equal(at, r.pos)
	byte_buf_release(&b)


void test_prefixed_malformed_lengths():
	byte_reader r
	byte_view v
	# Declared length longer than the remaining input.
	byte_reader_init(&r, c"\x05abc", 4)
	assert_equal(0, byte_reader_prefixed(&r, BYTES_PREFIX_U8, 100, &v))
	assert_equal(BYTES_TRUNCATED, byte_reader_status(&r))
	assert_equal(0, r.pos)
	# A u32 length with bit 31 set: on x86 the word is -1, never a usable
	# length even under the widest max; on x64 it is 4294967295, which
	# passes that max and then fails the remaining-length check.
	byte_reader_init(&r, c"\xff\xff\xff\xffabc", 7)
	assert_equal(0, byte_reader_prefixed(&r, BYTES_PREFIX_U32BE, checked_int_max(), &v))
	if (is64()): assert_equal(BYTES_TRUNCATED, byte_reader_status(&r))
	else: assert_equal(BYTES_TOO_LARGE, byte_reader_status(&r))
	assert_equal(0, r.pos)
	byte_reader_init(&r, c"\xff\xff\xff\xffabc", 7)
	assert_equal(0, byte_reader_prefixed(&r, BYTES_PREFIX_U32BE, 1 << 20, &v))
	assert_equal(BYTES_TOO_LARGE, byte_reader_status(&r))
	# Truncated prefix.
	byte_reader_init(&r, c"\x00", 1)
	assert_equal(0, byte_reader_prefixed(&r, BYTES_PREFIX_U16BE, 10, &v))
	assert_equal(BYTES_TRUNCATED, byte_reader_status(&r))
	# Malformed varint prefix.
	byte_reader_init(&r, c"\x80\x00", 2)
	assert_equal(0, byte_reader_prefixed(&r, BYTES_PREFIX_VARINT, 10, &v))
	assert_equal(BYTES_MALFORMED, byte_reader_status(&r))
	# Unknown kind and negative max.
	byte_reader_init(&r, c"\x00", 1)
	assert_equal(0, byte_reader_prefixed(&r, 99, 10, &v))
	assert_equal(BYTES_INVALID, byte_reader_status(&r))
	byte_reader_init(&r, c"\x00", 1)
	assert_equal(0, byte_reader_prefixed(&r, BYTES_PREFIX_U8, 0 - 1, &v))
	assert_equal(BYTES_INVALID, byte_reader_status(&r))


void test_writer_range_and_limits():
	byte_buf b
	byte_buf_init(&b, 6)
	byte_writer w
	byte_writer_init(&w, &b)
	assert_equal(0, byte_writer_u8(&w, 256))
	assert_equal(BYTES_OVERFLOW, byte_writer_status(&w))
	assert_equal(0, b.length)
	byte_writer_init(&w, &b)
	assert_equal(0, byte_writer_u16be(&w, 0 - 1))
	assert_equal(BYTES_OVERFLOW, byte_writer_status(&w))
	byte_writer_init(&w, &b)
	if (is64()):
		assert_equal(0, byte_writer_u32be(&w, 1 << 32))
		assert_equal(BYTES_OVERFLOW, byte_writer_status(&w))
		byte_writer_init(&w, &b)
		assert_equal(0, byte_writer_u32be(&w, checked_int_min()))
		assert_equal(BYTES_OVERFLOW, byte_writer_status(&w))
		# Both spellings of the all-ones pattern are accepted.
		byte_writer_init(&w, &b)
		assert_equal(1, byte_writer_u32be(&w, 0 - 1))
		expect_bytes(&b, c"\xff\xff\xff\xff", 4)
		byte_buf_clear(&b)
		assert_equal(1, byte_writer_u32be(&w, bytes_mask32()))
		expect_bytes(&b, c"\xff\xff\xff\xff", 4)
		byte_buf_clear(&b)
	else:
		assert_equal(1, byte_writer_u32be(&w, 0 - 1))
		expect_bytes(&b, c"\xff\xff\xff\xff", 4)
		byte_buf_clear(&b)
	# The buffer cap: a prefixed write that does not fit leaves nothing.
	byte_writer_init(&w, &b)
	assert_equal(1, byte_writer_bytes(&w, c"abc", 3))
	assert_equal(0, byte_writer_prefixed(&w, BYTES_PREFIX_U8, c"xyz", 3))
	assert_equal(BYTES_TOO_LARGE, byte_writer_status(&w))
	expect_bytes(&b, c"abc", 3)
	# Sticky: a write that would fit now still fails.
	assert_equal(0, byte_writer_u8(&w, 1))
	assert_equal(3, b.length)
	# A prefix that does not fit its field.
	byte_buf_clear(&b)
	byte_writer_init(&w, &b)
	assert_equal(0, byte_writer_length(&w, BYTES_PREFIX_U8, 256))
	assert_equal(BYTES_OVERFLOW, byte_writer_status(&w))
	byte_buf_release(&b)


void test_status_names():
	assert_strings_equal(c"truncated", bytes_status_name(BYTES_TRUNCATED))
	assert_strings_equal(c"malformed", bytes_status_name(BYTES_MALFORMED))
	assert_strings_equal(c"too_large", bytes_status_name(BYTES_TOO_LARGE))
