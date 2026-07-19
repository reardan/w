# wbuild: x64
/*
libs/extras/protobuf/{varint,wire,message}.w conformance tests
(docs/projects/protobuf.md, stage 1: "hand-written descriptors +
golden-vector tests", following tests/compress_inflate_test.w's
hand-crafted-fixture shape per the design doc §8's test strategy).

Every hex vector below is derived by hand from the proto3 wire-format
spec (field number, wire type, value -> bytes) and cited at its use
site; several are Google's own canonical worked examples from the
protobuf "Encoding" guide (the field-1/150, field-2/"testing", and
packed-repeated field-4/[3,270,86942] cases) -- independently
verifiable prior art, not just this file's own arithmetic, matching the
precedent tests/compress_inflate_test.w set for cross-checking against
an external reference.

Struct field offsets are computed at runtime via
`cast(int, &s.field) - cast(int, &s)` (the same idiom
tests/increment_test.w and tests/ptr_add_test.w already use for pointer
differences) rather than hand-counted, since W struct fields are
byte-packed with no alignment padding (docs/projects/protobuf.md §3)
but field widths still differ by target (`int`/pointers are
word-sized). This sidesteps a real gotcha found while writing these
tests: a fixed-size array (`T[N]`) struct field is NOT flat inline
storage -- it carries a small runtime header before its data
(compiler/type_table.w:237's `type_push_array` size formula,
`(2*word_size) + length*element_size`; confirmed empirically and
logged in docs/projects/ai_tooling_next_steps.md), so raw byte-offset
access into a `T[N]` field would silently read the header, not the
data. This suite never uses a `T[N]` struct field for that reason --
FIXED64-shaped coverage below uses two adjacent int32 words instead
(see pb_test_fixed_msg). Descriptor structs/storage are file-scope
globals (W has no nested/local `struct` declarations), populated fresh
by each test's own `..._desc_init()`-style helper.

The x64-only int64/uint64/sint64/double kinds (which need a real
int64-typed struct field to exercise, and can't share this file's
32-bit default twin since int64 is a hard compile error there) live in
tests/x64_protobuf_test.w, a hand-written build.base.json target
mirroring tests/x64_int64_test.w's own placement.
*/
import lib.testing
import lib.result
import lib.rand
import libs.extras.protobuf.varint
import libs.extras.protobuf.wire
import libs.extras.protobuf.message


void pb_expect_bytes(char* label, char* got, int got_len, char* want, int want_len):
	if (got_len != want_len):
		print2(label)
		print2(c": length mismatch got=")
		print2(itoa(got_len))
		print2(c" want=")
		println2(itoa(want_len))
		exit(1)
	int i = 0
	while (i < want_len):
		if ((got[i] & 255) != (want[i] & 255)):
			print2(label)
			print2(c": byte mismatch at offset ")
			print2(itoa(i))
			print2(c" got=")
			print2(itoa(got[i] & 255))
			print2(c" want=")
			println2(itoa(want[i] & 255))
			exit(1)
		i = i + 1


/* ---- varint / zigzag / tag core (docs/projects/protobuf.md §2, §6.1) */


void test_varint_scalar_edges():
	char[16] buf
	int n = 0

	# 0 and 1: single byte, no continuation.
	n = varint_encode_u32(0, buf)
	pb_expect_bytes(c"varint(0)", buf, n, c"\x00", 1)
	n = varint_encode_u32(1, buf)
	pb_expect_bytes(c"varint(1)", buf, n, c"\x01", 1)

	# 127: the largest one-byte varint (7 payload bits, no continuation).
	n = varint_encode_u32(127, buf)
	pb_expect_bytes(c"varint(127)", buf, n, c"\x7f", 1)

	# 128: the smallest value needing a second byte (continuation bit
	# set on the first byte, 0x80 0x01).
	n = varint_encode_u32(128, buf)
	pb_expect_bytes(c"varint(128)", buf, n, c"\x80\x01", 2)

	# 300 = 0b1_0010_1100: group0 = 0101100 (0x2c) with continuation,
	# group1 = 0000010 (2) -- 0xac 0x02.
	n = varint_encode_u32(300, buf)
	pb_expect_bytes(c"varint(300)", buf, n, c"\xac\x02", 2)

	# INT32_MAX (2147483647 = 0x7fffffff, 31 ones): five groups of 7
	# bits, the last carrying only the top single bit -- ff ff ff ff 07,
	# a widely-published reference value for this exact input.
	n = varint_encode_u32(2147483647, buf)
	pb_expect_bytes(c"varint(INT32_MAX)", buf, n, c"\xff\xff\xff\xff\x07", 5)

	# 150: Google's own canonical protobuf "Encoding" guide varint
	# example (150 = 0b1001_0110 -> 96 01).
	n = varint_encode_u32(150, buf)
	pb_expect_bytes(c"varint(150)", buf, n, c"\x96\x01", 2)

	# Negative int32 as a 10-byte varint (docs/projects/protobuf.md §2):
	# a plain (non-zigzag) int32 field's negative value sign-extends to
	# 64 bits before encoding, so -1 (all 64 bits set) needs nine 0xff
	# continuation bytes plus a final 0x01 (the lone surviving bit at
	# position 63), and -2 differs only in its low group (0x7e -> 0xfe).
	n = varint_encode_i32(-1, buf)
	pb_expect_bytes(c"varint_i32(-1)", buf, n, c"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", 10)
	n = varint_encode_i32(-2, buf)
	pb_expect_bytes(c"varint_i32(-2)", buf, n, c"\xfe\xff\xff\xff\xff\xff\xff\xff\xff\x01", 10)


void test_varint_decode_roundtrip():
	char[16] buf
	int n = varint_encode_i32(-1, buf)
	int v = 0
	int consumed = varint_decode_i32(buf, n, &v)
	assert_equal(n, consumed)
	assert_equal(-1, v)

	n = varint_encode_i32(-2, buf)
	consumed = varint_decode_i32(buf, n, &v)
	assert_equal(n, consumed)
	assert_equal(-2, v)

	n = varint_encode_u32(300, buf)
	int uv = 0
	consumed = varint_decode_u32(buf, n, &uv)
	assert_equal(n, consumed)
	assert_equal(300, uv)

	n = varint_encode_u32(2147483647, buf)
	consumed = varint_decode_u32(buf, n, &uv)
	assert_equal(n, consumed)
	assert_equal(2147483647, uv)


# sint32 zigzag pairs (docs/projects/protobuf.md §2): 0<->0, -1<->1,
# 1<->2, -2<->3, 2<->4 -- the canonical small-value zigzag table.
void test_zigzag32_pairs():
	assert_equal(0, zigzag_encode32(0))
	assert_equal(1, zigzag_encode32(-1))
	assert_equal(2, zigzag_encode32(1))
	assert_equal(3, zigzag_encode32(-2))
	assert_equal(4, zigzag_encode32(2))
	assert_equal(0, zigzag_decode32(0))
	assert_equal(-1, zigzag_decode32(1))
	assert_equal(1, zigzag_decode32(2))
	assert_equal(-2, zigzag_decode32(3))
	assert_equal(2, zigzag_decode32(4))


# zigzag(INT32_MAX) = 2*INT32_MAX = 4294967294 (0xfffffffe); the wire
# bytes are the load-bearing check here since the host `int` prints the
# raw bit pattern (negative on the 32-bit target) rather than the
# unsigned magnitude.
void test_zigzag32_max_wire_bytes():
	int enc = zigzag_encode32(2147483647)
	assert_equal(2147483647, zigzag_decode32(enc))
	char[16] buf
	int n = varint_encode_u32(enc, buf)
	pb_expect_bytes(c"zigzag(INT32_MAX)", buf, n, c"\xfe\xff\xff\xff\x0f", 5)


# Direct (lo, hi) 32-bit-pair coverage of a full 64-bit value -- the
# part of the codec docs/projects/protobuf.md flags as needing special
# handling on the 32-bit target (no native 64-bit register to hold a
# sign-extended value), fully exercisable on the default arch since it
# never touches the int64 type. varint_mask32() is all 64 bits set when
# used as both halves.
void test_varint_parts_64bit_negative_one():
	char[16] buf
	int mask = varint_mask32()
	int n = varint_encode_parts(mask, mask, buf)
	pb_expect_bytes(c"parts(-1 as 64-bit)", buf, n, c"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", 10)
	int lo = 0
	int hi = 0
	int consumed = varint_decode_parts(buf, n, &lo, &hi)
	assert_equal(n, consumed)
	assert_equal(mask, lo)
	assert_equal(mask, hi)


void test_wire_tag_encode_decode():
	char[16] buf
	# field 1, varint: (1<<3)|0 = 8.
	int n = wire_tag_encode(1, PB_WIRE_VARINT(), buf)
	pb_expect_bytes(c"tag(1,varint)", buf, n, c"\x08", 1)
	# field 2, length-delimited: (2<<3)|2 = 18 = 0x12.
	n = wire_tag_encode(2, PB_WIRE_LENGTH_DELIMITED(), buf)
	pb_expect_bytes(c"tag(2,length)", buf, n, c"\x12", 1)
	# field 4, length-delimited (a packed-repeated field's tag):
	# (4<<3)|2 = 34 = 0x22.
	n = wire_tag_encode(4, PB_WIRE_LENGTH_DELIMITED(), buf)
	pb_expect_bytes(c"tag(4,length)", buf, n, c"\x22", 1)

	int field = 0
	int wtype = 0
	int consumed = wire_tag_decode(c"\x08", 1, &field, &wtype)
	assert_equal(1, consumed)
	assert_equal(1, field)
	assert_equal(PB_WIRE_VARINT(), wtype)


void test_wire_skip_field_each_wire_type():
	# varint: one byte, no continuation.
	assert_equal(1, wire_skip_field(c"\x2a", 1, PB_WIRE_VARINT()))
	# varint: two bytes (128 encoded).
	assert_equal(2, wire_skip_field(c"\x80\x01", 2, PB_WIRE_VARINT()))
	# fixed64: always exactly 8 bytes regardless of content.
	assert_equal(8, wire_skip_field(c"\x01\x02\x03\x04\x05\x06\x07\x08", 8, PB_WIRE_FIXED64()))
	# fixed32: always exactly 4 bytes.
	assert_equal(4, wire_skip_field(c"\x01\x02\x03\x04", 4, PB_WIRE_FIXED32()))
	# length-delimited: a 1-byte length prefix (3) plus 3 payload bytes.
	assert_equal(4, wire_skip_field(c"\x03\x61\x62\x63", 4, PB_WIRE_LENGTH_DELIMITED()))
	# truncated fixed32 (only 2 of 4 bytes present).
	assert_equal(0, wire_skip_field(c"\x01\x02", 2, PB_WIRE_FIXED32()))
	# unsupported wire type (3 = start group).
	assert_equal(0, wire_skip_field(c"\x00", 1, 3))


/* ---- message-level encode/decode -------------------------------- */


struct pb_test_simple_msg:
	int32 a
	pb_bytes b


pb_field_desc[2] pb_test_simple_fields
pb_message_desc pb_test_simple_desc


void pb_test_simple_desc_init():
	pb_test_simple_msg m
	pb_test_simple_fields[0].number = 1
	pb_test_simple_fields[0].kind = PB_KIND_INT32()
	pb_test_simple_fields[0].offset = cast(int, &m.a) - cast(int, &m)
	pb_test_simple_fields[0].aux = 0
	pb_test_simple_fields[1].number = 2
	pb_test_simple_fields[1].kind = PB_KIND_STRING()
	pb_test_simple_fields[1].offset = cast(int, &m.b) - cast(int, &m)
	pb_test_simple_fields[1].aux = 0
	pb_test_simple_desc.field_count = 2
	pb_test_simple_desc.fields = pb_test_simple_fields
	pb_test_simple_desc.struct_size = 4 + 2 * __word_size__


wresult[char*]* pb_test_simple_decode(char* data, int length):
	char* buf = malloc(pb_test_simple_desc.struct_size)
	int i = 0
	while (i < pb_test_simple_desc.struct_size):
		buf[i] = 0
		i = i + 1
	return pb_decode(&pb_test_simple_desc, data, length, buf)


# Google's own canonical two-field message example: field 1 (int32) =
# 150, field 2 (string) = "testing" -> 08 96 01 12 07 'testing'.
void test_message_two_field_google_example():
	pb_test_simple_desc_init()
	pb_test_simple_msg m
	m.a = 150
	m.b.data = c"testing"
	m.b.length = 7
	int out_len = 0
	char* out = pb_encode(&pb_test_simple_desc, cast(char*, &m), &out_len)
	pb_expect_bytes(c"two-field message", out, out_len, c"\x08\x96\x01\x12\x07\x74\x65\x73\x74\x69\x6e\x67", 12)

	wresult[char*]* r = pb_test_simple_decode(out, out_len)
	assert_equal(1, result_is_ok[char*](r))
	pb_test_simple_msg* decoded = cast(pb_test_simple_msg*, result_value[char*](r))
	assert_equal(150, decoded.a)
	assert_equal(7, decoded.b.length)
	assert_strings_equal(c"testing", decoded.b.data)
	free(decoded.b.data)
	free(cast(char*, decoded))
	result_free[char*](r)
	free(out)


void test_message_unknown_field_skip():
	pb_test_simple_desc_init()
	# field 1 = 150 (known), field 99 (unknown, varint, value 42:
	# tag = (99<<3)|0 = 792 = 0x98 0x06), field 2 = "hi" (known) -- the
	# unknown field must be skipped without disturbing the known ones.
	char* data = c"\x08\x96\x01\x98\x06\x2a\x12\x02\x68\x69"
	int length = 10
	wresult[char*]* r = pb_test_simple_decode(data, length)
	assert_equal(1, result_is_ok[char*](r))
	pb_test_simple_msg* decoded = cast(pb_test_simple_msg*, result_value[char*](r))
	assert_equal(150, decoded.a)
	assert_equal(2, decoded.b.length)
	assert_strings_equal(c"hi", decoded.b.data)
	free(decoded.b.data)
	free(cast(char*, decoded))
	result_free[char*](r)


struct pb_test_blob_msg:
	pb_bytes data
	pb_bytes utf8


pb_field_desc[2] pb_test_blob_fields
pb_message_desc pb_test_blob_desc


void pb_test_blob_desc_init():
	pb_test_blob_msg m
	pb_test_blob_fields[0].number = 1
	pb_test_blob_fields[0].kind = PB_KIND_BYTES()
	pb_test_blob_fields[0].offset = cast(int, &m.data) - cast(int, &m)
	pb_test_blob_fields[0].aux = 0
	pb_test_blob_fields[1].number = 2
	pb_test_blob_fields[1].kind = PB_KIND_STRING()
	pb_test_blob_fields[1].offset = cast(int, &m.utf8) - cast(int, &m)
	pb_test_blob_fields[1].aux = 0
	pb_test_blob_desc.field_count = 2
	pb_test_blob_desc.fields = pb_test_blob_fields
	pb_test_blob_desc.struct_size = 4 * __word_size__


void test_message_bytes_embedded_nul_and_utf8_string():
	pb_test_blob_desc_init()
	pb_test_blob_msg m
	# bytes: "a\x00b" (3 bytes, embedded NUL). string: "caf\xc3\xa9"
	# ("cafe" with an e-acute, U+00E9, UTF-8 encoded).
	char* raw = c"a\x00b"
	m.data.data = raw
	m.data.length = 3
	char* text = c"caf\xc3\xa9"
	m.utf8.data = text
	m.utf8.length = 5
	int out_len = 0
	char* out = pb_encode(&pb_test_blob_desc, cast(char*, &m), &out_len)
	# tag(1,length)=0x0a len=3 [61 00 62]; tag(2,length)=0x12 len=5
	# [63 61 66 c3 a9].
	pb_expect_bytes(c"bytes+utf8", out, out_len, c"\x0a\x03\x61\x00\x62\x12\x05\x63\x61\x66\xc3\xa9", 12)

	char* buf = malloc(pb_test_blob_desc.struct_size)
	int i = 0
	while (i < pb_test_blob_desc.struct_size):
		buf[i] = 0
		i = i + 1
	wresult[char*]* r = pb_decode(&pb_test_blob_desc, out, out_len, buf)
	assert_equal(1, result_is_ok[char*](r))
	pb_test_blob_msg* decoded = cast(pb_test_blob_msg*, buf)
	assert_equal(3, decoded.data.length)
	assert_equal('a', decoded.data.data[0])
	assert_equal(0, decoded.data.data[1])
	assert_equal('b', decoded.data.data[2])
	assert_equal(5, decoded.utf8.length)
	int j = 0
	while (j < 5):
		assert_equal(text[j] & 255, decoded.utf8.data[j] & 255)
		j = j + 1
	free(decoded.data.data)
	free(decoded.utf8.data)
	result_free[char*](r)
	free(out)
	free(buf)


void test_message_empty_string_and_bytes_omitted_on_encode():
	pb_test_blob_desc_init()
	pb_test_blob_msg m
	m.data.data = cast(char*, 0)
	m.data.length = 0
	m.utf8.data = cast(char*, 0)
	m.utf8.length = 0
	int out_len = 0
	char* out = pb_encode(&pb_test_blob_desc, cast(char*, &m), &out_len)
	assert_equal(0, out_len)
	free(out)


# fixed32 (a float field) plus "fixed64-shaped" coverage via two
# adjacent int32 words rather than a T[N] array field (see this file's
# header comment on why: fixed arrays carry a hidden header).
struct pb_test_fixed_msg:
	float f
	int32 raw64_lo
	int32 raw64_hi


pb_field_desc[2] pb_test_fixed_fields
pb_message_desc pb_test_fixed_desc


void pb_test_fixed_desc_init():
	pb_test_fixed_msg m
	pb_test_fixed_fields[0].number = 1
	pb_test_fixed_fields[0].kind = PB_KIND_FIXED32()
	pb_test_fixed_fields[0].offset = cast(int, &m.f) - cast(int, &m)
	pb_test_fixed_fields[0].aux = 0
	pb_test_fixed_fields[1].number = 2
	pb_test_fixed_fields[1].kind = PB_KIND_FIXED64()
	pb_test_fixed_fields[1].offset = cast(int, &m.raw64_lo) - cast(int, &m)
	pb_test_fixed_fields[1].aux = 0
	pb_test_fixed_desc.field_count = 2
	pb_test_fixed_desc.fields = pb_test_fixed_fields
	pb_test_fixed_desc.struct_size = 12


void test_message_fixed32_and_fixed64():
	pb_test_fixed_desc_init()
	pb_test_fixed_msg m
	m.f = 1.0
	m.raw64_lo = 1
	m.raw64_hi = 0
	int out_len = 0
	char* out = pb_encode(&pb_test_fixed_desc, cast(char*, &m), &out_len)
	# tag(1,fixed32)=0x0d then float 1.0's LE bytes (0x3f800000 ->
	# 00 00 80 3f); tag(2,fixed64)=0x11 then the 8 raw bytes we set by
	# hand (value 1, little-endian).
	pb_expect_bytes(c"fixed32/64", out, out_len, c"\x0d\x00\x00\x80\x3f\x11\x01\x00\x00\x00\x00\x00\x00\x00", 14)

	char* buf = malloc(pb_test_fixed_desc.struct_size)
	int i = 0
	while (i < pb_test_fixed_desc.struct_size):
		buf[i] = 0
		i = i + 1
	wresult[char*]* r = pb_decode(&pb_test_fixed_desc, out, out_len, buf)
	assert_equal(1, result_is_ok[char*](r))
	pb_test_fixed_msg* decoded = cast(pb_test_fixed_msg*, buf)
	assert_equal(1, decoded.f == m.f)
	assert_equal(1, decoded.raw64_lo)
	assert_equal(0, decoded.raw64_hi)
	result_free[char*](r)
	free(out)
	free(buf)


# Nested message: outer field 3 embeds inner{ x=1 }=5.
struct pb_test_inner:
	int32 x


struct pb_test_outer:
	pb_test_inner* inner


pb_field_desc[1] pb_test_inner_fields
pb_message_desc pb_test_inner_desc
pb_field_desc[1] pb_test_outer_fields
pb_message_desc pb_test_outer_desc


void pb_test_nested_desc_init():
	pb_test_inner im
	pb_test_inner_fields[0].number = 1
	pb_test_inner_fields[0].kind = PB_KIND_INT32()
	pb_test_inner_fields[0].offset = cast(int, &im.x) - cast(int, &im)
	pb_test_inner_fields[0].aux = 0
	pb_test_inner_desc.field_count = 1
	pb_test_inner_desc.fields = pb_test_inner_fields
	pb_test_inner_desc.struct_size = 4

	pb_test_outer om
	pb_test_outer_fields[0].number = 3
	pb_test_outer_fields[0].kind = PB_KIND_MESSAGE()
	pb_test_outer_fields[0].offset = cast(int, &om.inner) - cast(int, &om)
	pb_test_outer_fields[0].aux = cast(int, &pb_test_inner_desc)
	pb_test_outer_desc.field_count = 1
	pb_test_outer_desc.fields = pb_test_outer_fields
	pb_test_outer_desc.struct_size = __word_size__


void test_message_nested():
	pb_test_nested_desc_init()
	pb_test_outer om
	pb_test_inner im
	im.x = 5
	om.inner = &im
	int out_len = 0
	char* out = pb_encode(&pb_test_outer_desc, cast(char*, &om), &out_len)
	# inner: tag(1,varint)=0x08 value=5 -> 08 05 (2 bytes). outer: field
	# 3, length-delimited: tag=(3<<3)|2=26=0x1a, length=2 -> 1a 02 08 05.
	pb_expect_bytes(c"nested", out, out_len, c"\x1a\x02\x08\x05", 4)

	char* buf = malloc(pb_test_outer_desc.struct_size)
	int i = 0
	while (i < pb_test_outer_desc.struct_size):
		buf[i] = 0
		i = i + 1
	wresult[char*]* r = pb_decode(&pb_test_outer_desc, out, out_len, buf)
	assert_equal(1, result_is_ok[char*](r))
	pb_test_outer* decoded = cast(pb_test_outer*, buf)
	assert_equal(1, cast(int, decoded.inner) != 0)
	assert_equal(5, decoded.inner.x)
	free(cast(char*, decoded.inner))
	result_free[char*](r)
	free(out)
	free(buf)


# Repeated packed int32, field 4, values [3, 270, 86942] -- Google's own
# canonical "Packed Repeated Fields" encoding-guide example.
struct pb_test_rep_msg:
	list[int32] values


pb_value_desc pb_test_rep_elem
pb_field_desc[1] pb_test_rep_fields
pb_message_desc pb_test_rep_desc


void pb_test_rep_desc_init():
	pb_test_rep_msg rm
	pb_test_rep_elem.kind = PB_KIND_INT32()
	pb_test_rep_elem.aux = 0
	pb_test_rep_fields[0].number = 4
	pb_test_rep_fields[0].kind = PB_KIND_REPEATED()
	pb_test_rep_fields[0].offset = cast(int, &rm.values) - cast(int, &rm)
	pb_test_rep_fields[0].aux = cast(int, &pb_test_rep_elem)
	pb_test_rep_desc.field_count = 1
	pb_test_rep_desc.fields = pb_test_rep_fields
	pb_test_rep_desc.struct_size = __word_size__


void test_message_repeated_packed():
	pb_test_rep_desc_init()
	pb_test_rep_msg rm
	rm.values = list[int32]{3, 270, 86942}
	int out_len = 0
	char* out = pb_encode(&pb_test_rep_desc, cast(char*, &rm), &out_len)
	# tag(4,length)=0x22, payload length=6: varint(3)=03,
	# varint(270)=8e 02, varint(86942)=9e a7 05.
	pb_expect_bytes(c"repeated packed", out, out_len, c"\x22\x06\x03\x8e\x02\x9e\xa7\x05", 8)

	char* buf = malloc(pb_test_rep_desc.struct_size)
	int i = 0
	while (i < pb_test_rep_desc.struct_size):
		buf[i] = 0
		i = i + 1
	wresult[char*]* r = pb_decode(&pb_test_rep_desc, out, out_len, buf)
	assert_equal(1, result_is_ok[char*](r))
	pb_test_rep_msg* decoded = cast(pb_test_rep_msg*, buf)
	assert_equal(3, decoded.values.length)
	assert_equal(3, decoded.values[0])
	assert_equal(270, decoded.values[1])
	assert_equal(86942, decoded.values[2])
	result_free[char*](r)
	free(out)
	free(buf)


# Repeated packed bool, field 4 (same shape as pb_test_rep_desc with a
# BOOL element): [1, 0, 1] packs to payload bytes 01 00 01. The decode
# assertions pin the element's full 4-byte width -- repeated decode
# stages each element in a reused stack slot, so a byte-0-only BOOL
# write would leak the slot's stale high bytes into the list values.
pb_value_desc pb_test_rep_bool_elem
pb_field_desc[1] pb_test_rep_bool_fields
pb_message_desc pb_test_rep_bool_desc


void pb_test_rep_bool_desc_init():
	pb_test_rep_msg rm
	pb_test_rep_bool_elem.kind = PB_KIND_BOOL()
	pb_test_rep_bool_elem.aux = 0
	pb_test_rep_bool_fields[0].number = 4
	pb_test_rep_bool_fields[0].kind = PB_KIND_REPEATED()
	pb_test_rep_bool_fields[0].offset = cast(int, &rm.values) - cast(int, &rm)
	pb_test_rep_bool_fields[0].aux = cast(int, &pb_test_rep_bool_elem)
	pb_test_rep_bool_desc.field_count = 1
	pb_test_rep_bool_desc.fields = pb_test_rep_bool_fields
	pb_test_rep_bool_desc.struct_size = __word_size__


void test_message_repeated_packed_bool():
	pb_test_rep_bool_desc_init()
	pb_test_rep_msg rm
	rm.values = list[int32]{1, 0, 1}
	int out_len = 0
	char* out = pb_encode(&pb_test_rep_bool_desc, cast(char*, &rm), &out_len)
	# tag(4,length)=0x22, payload length=3, one varint per element.
	char[8] want
	want[0] = 0x22
	want[1] = 3
	want[2] = 1
	want[3] = 0
	want[4] = 1
	pb_expect_bytes(c"repeated packed bool", out, out_len, want, 5)

	char* buf = malloc(pb_test_rep_bool_desc.struct_size)
	int i = 0
	while (i < pb_test_rep_bool_desc.struct_size):
		buf[i] = 0
		i = i + 1
	wresult[char*]* r = pb_decode(&pb_test_rep_bool_desc, out, out_len, buf)
	assert_equal(1, result_is_ok[char*](r))
	pb_test_rep_msg* decoded = cast(pb_test_rep_msg*, buf)
	assert_equal(3, decoded.values.length)
	assert_equal(1, decoded.values[0])
	assert_equal(0, decoded.values[1])
	assert_equal(1, decoded.values[2])
	result_free[char*](r)
	free(out)
	free(buf)


# A decoder must accept both packed and unpacked encodings of the same
# repeated scalar field (docs/projects/protobuf.md §2 -- proto2
# producers default to unpacked). Hand-built unpacked form of the same
# [3, 270, 86942]: field 4, wire type 0 (varint), one tag+value per
# element: tag=(4<<3)|0=32=0x20.
void test_message_repeated_unpacked_decode_is_accepted():
	pb_test_rep_desc_init()
	char* data = c"\x20\x03\x20\x8e\x02\x20\x9e\xa7\x05"
	int length = 9
	char* buf = malloc(pb_test_rep_desc.struct_size)
	int i = 0
	while (i < pb_test_rep_desc.struct_size):
		buf[i] = 0
		i = i + 1
	wresult[char*]* r = pb_decode(&pb_test_rep_desc, data, length, buf)
	assert_equal(1, result_is_ok[char*](r))
	pb_test_rep_msg* decoded = cast(pb_test_rep_msg*, buf)
	assert_equal(3, decoded.values.length)
	assert_equal(3, decoded.values[0])
	assert_equal(270, decoded.values[1])
	assert_equal(86942, decoded.values[2])
	result_free[char*](r)
	free(buf)


# Repeated message-typed fields can't be packed (they already carry
# their own length delimiter) -- always one tag+length-delimited entry
# per element (docs/projects/protobuf.md §2).
struct pb_test_pt:
	int32 x
	int32 y


struct pb_test_poly:
	list[pb_test_pt] points


pb_field_desc[2] pb_test_pt_fields
pb_message_desc pb_test_pt_desc
pb_value_desc pb_test_poly_elem
pb_field_desc[1] pb_test_poly_fields
pb_message_desc pb_test_poly_desc


void pb_test_poly_desc_init():
	pb_test_pt pt
	pb_test_pt_fields[0].number = 1
	pb_test_pt_fields[0].kind = PB_KIND_INT32()
	pb_test_pt_fields[0].offset = cast(int, &pt.x) - cast(int, &pt)
	pb_test_pt_fields[0].aux = 0
	pb_test_pt_fields[1].number = 2
	pb_test_pt_fields[1].kind = PB_KIND_INT32()
	pb_test_pt_fields[1].offset = cast(int, &pt.y) - cast(int, &pt)
	pb_test_pt_fields[1].aux = 0
	pb_test_pt_desc.field_count = 2
	pb_test_pt_desc.fields = pb_test_pt_fields
	pb_test_pt_desc.struct_size = 8

	pb_test_poly_elem.kind = PB_KIND_MESSAGE()
	pb_test_poly_elem.aux = cast(int, &pb_test_pt_desc)

	pb_test_poly pm
	pb_test_poly_fields[0].number = 5
	pb_test_poly_fields[0].kind = PB_KIND_REPEATED()
	pb_test_poly_fields[0].offset = cast(int, &pm.points) - cast(int, &pm)
	pb_test_poly_fields[0].aux = cast(int, &pb_test_poly_elem)
	pb_test_poly_desc.field_count = 1
	pb_test_poly_desc.fields = pb_test_poly_fields
	pb_test_poly_desc.struct_size = __word_size__


void test_message_repeated_message_unpacked():
	pb_test_poly_desc_init()
	pb_test_poly pm
	pm.points = new list[pb_test_pt]
	pb_test_pt p
	p.x = 0
	p.y = 0
	pm.points.push(p)
	p.x = 4
	p.y = 0
	pm.points.push(p)
	int out_len = 0
	char* out = pb_encode(&pb_test_poly_desc, cast(char*, &pm), &out_len)
	# tag(5,length)=(5<<3)|2=42=0x2a. Point (0,0) is entirely default,
	# so it encodes as an empty submessage (2a 00). Point (4,0): x=4
	# encodes (tag 08, value 04), y=0 is omitted -> submessage "08 04"
	# (length 2), giving 2a 02 08 04.
	pb_expect_bytes(c"repeated message", out, out_len, c"\x2a\x00\x2a\x02\x08\x04", 6)

	char* buf = malloc(pb_test_poly_desc.struct_size)
	int i = 0
	while (i < pb_test_poly_desc.struct_size):
		buf[i] = 0
		i = i + 1
	wresult[char*]* r = pb_decode(&pb_test_poly_desc, out, out_len, buf)
	assert_equal(1, result_is_ok[char*](r))
	pb_test_poly* decoded = cast(pb_test_poly*, buf)
	assert_equal(2, decoded.points.length)
	pb_test_pt got0 = decoded.points[0]
	assert_equal(0, got0.x)
	assert_equal(0, got0.y)
	pb_test_pt got1 = decoded.points[1]
	assert_equal(4, got1.x)
	assert_equal(0, got1.y)
	result_free[char*](r)
	free(out)
	free(buf)


/* ---- decode error paths (PB_ERR_*) -------------------------------- */


void test_message_decode_error_paths():
	pb_test_simple_desc_init()

	# Tag present but the varint payload never arrives at all.
	wresult[char*]* r1 = pb_test_simple_decode(c"\x08", 1)
	assert_equal(1, result_is_error[char*](r1))
	assert_equal(PB_ERR_TRUNCATED(), result_code[char*](r1))
	result_free[char*](r1)

	# A lone continuation byte with nothing following it.
	wresult[char*]* r2 = pb_test_simple_decode(c"\x08\x80", 2)
	assert_equal(1, result_is_error[char*](r2))
	assert_equal(PB_ERR_TRUNCATED(), result_code[char*](r2))
	result_free[char*](r2)

	# 11 continuation bytes -- exceeds the 10-byte varint maximum.
	wresult[char*]* r3 = pb_test_simple_decode(c"\x08\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01", 12)
	assert_equal(1, result_is_error[char*](r3))
	assert_equal(PB_ERR_BAD_VARINT(), result_code[char*](r3))
	result_free[char*](r3)

	# field 2 (string) declares a length exceeding the remaining buffer.
	wresult[char*]* r4 = pb_test_simple_decode(c"\x12\x05\x68\x69", 4)
	assert_equal(1, result_is_error[char*](r4))
	assert_equal(PB_ERR_LENGTH_OVERRUN(), result_code[char*](r4))
	result_free[char*](r4)

	# field 1 declared with wire type 3 (start group) -- unsupported.
	wresult[char*]* r5 = pb_test_simple_decode(c"\x0b", 1)
	assert_equal(1, result_is_error[char*](r5))
	assert_equal(PB_ERR_BAD_WIRE_TYPE(), result_code[char*](r5))
	result_free[char*](r5)

	# Unknown field number 7 with wire type 3 (group) -- also
	# unsupported, even though field 7 isn't in the descriptor.
	wresult[char*]* r6 = pb_test_simple_decode(c"\x3b", 1)
	assert_equal(1, result_is_error[char*](r6))
	assert_equal(PB_ERR_BAD_WIRE_TYPE(), result_code[char*](r6))
	result_free[char*](r6)


/* ---- round-trip property: decode(encode(x)) == x ------------------ */


void test_message_roundtrip_property_simple():
	pb_test_simple_desc_init()
	rand_state rs
	rand_init(&rs, 20260719)
	int trial = 0
	while (trial < 200):
		pb_test_simple_msg m
		# A zero value would be omitted on encode and read back as the
		# same zero default either way, so keep 'a' nonzero to exercise
		# the actual varint path every trial (zero-field omission is
		# covered by its own dedicated test above).
		m.a = rand_below(&rs, 2000000000) - 1000000000
		if (m.a == 0):
			m.a = 1
		int slen = rand_below(&rs, 12)
		char* s = malloc(slen + 1)
		int i = 0
		while (i < slen):
			s[i] = 'a' + rand_below(&rs, 26)
			i = i + 1
		s[slen] = 0
		m.b.data = s
		m.b.length = slen

		int out_len = 0
		char* out = pb_encode(&pb_test_simple_desc, cast(char*, &m), &out_len)
		wresult[char*]* r = pb_test_simple_decode(out, out_len)
		assert_equal(1, result_is_ok[char*](r))
		pb_test_simple_msg* decoded = cast(pb_test_simple_msg*, result_value[char*](r))
		assert_equal(m.a, decoded.a)
		assert_equal(slen, decoded.b.length)
		int j = 0
		while (j < slen):
			assert_equal(s[j] & 255, decoded.b.data[j] & 255)
			j = j + 1
		if (slen > 0):
			free(decoded.b.data)
		free(cast(char*, decoded))
		result_free[char*](r)
		free(out)
		free(s)
		trial = trial + 1


void test_message_roundtrip_property_repeated():
	pb_test_rep_desc_init()
	rand_state rs
	rand_init(&rs, 6220719)
	int trial = 0
	while (trial < 200):
		pb_test_rep_msg rm
		rm.values = new list[int32]
		int count = rand_below(&rs, 8) + 1
		int i = 0
		while (i < count):
			int v = rand_below(&rs, 200000) - 100000
			rm.values.push(v)
			i = i + 1

		int out_len = 0
		char* out = pb_encode(&pb_test_rep_desc, cast(char*, &rm), &out_len)
		char* buf = malloc(pb_test_rep_desc.struct_size)
		int z = 0
		while (z < pb_test_rep_desc.struct_size):
			buf[z] = 0
			z = z + 1
		wresult[char*]* r = pb_decode(&pb_test_rep_desc, out, out_len, buf)
		assert_equal(1, result_is_ok[char*](r))
		pb_test_rep_msg* decoded = cast(pb_test_rep_msg*, buf)
		assert_equal(count, decoded.values.length)
		int j = 0
		while (j < count):
			assert_equal(rm.values[j], decoded.values[j])
			j = j + 1
		result_free[char*](r)
		free(out)
		free(buf)
		trial = trial + 1
