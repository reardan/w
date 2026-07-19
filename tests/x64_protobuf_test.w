/*
libs/extras/protobuf's INT64/UINT64/SINT64/FIXED64(double) kinds against
real int64/uint64/float64-typed struct fields (docs/projects/
protobuf.md, stage 1). int64/uint64/float64 are x64-only types
(README.md's Language snapshot), so this source cannot share a 32-bit
default twin with tests/protobuf_test.w -- mirrors tests/
x64_int64_test.w's own placement (a hand-written, x64-only build.json
target rather than a `# wbuild: x64` directive, since that directive
generates a 32-bit twin from the SAME source, which int64/float64
declarations would fail to compile under).

message.w's generic codec never names the int64/uint64/float64 types
itself (it reads/writes 64-bit-wide fields as two adjacent int32 words,
or via a raw byte copy for FIXED64) precisely so it compiles unchanged
on the 32-bit target; this file is what actually exercises that
machinery against genuine wide-typed fields, on the one target where
they exist. varint.w's zigzag_encode64/decode64 convenience wrappers
(which take a native `int`, meaningful as a full 64-bit register only
here) get their own direct coverage too.
*/
import lib.lib
import lib.assert
import lib.result
import libs.extras.protobuf.varint
import libs.extras.protobuf.wire
import libs.extras.protobuf.message


void x64pb_expect_bytes(char* label, char* got, int got_len, char* want, int want_len):
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
			println2(itoa(i))
			exit(1)
		i = i + 1


void test_zigzag64_native_pairs():
	int64 a = -1
	assert_equal(1, zigzag_encode64(a))
	int64 back = zigzag_decode64(1)
	assert_equal(1, back == -1)

	int64 b = 2147483648
	int enc_b = zigzag_encode64(b)
	int64 back_b = zigzag_decode64(enc_b)
	assert_equal(1, back_b == b)

	int64 big = 900000000
	big = big * 10
	int64 c = 0 - big
	int enc_c = zigzag_encode64(c)
	int64 back_c = zigzag_decode64(enc_c)
	assert_equal(1, back_c == c)


struct x64pb_wide_msg:
	int64 a
	uint64 b
	int64 c
	float64 d


pb_field_desc[4] x64pb_wide_fields
pb_message_desc x64pb_wide_desc


void x64pb_wide_desc_init():
	x64pb_wide_msg m
	x64pb_wide_fields[0].number = 1
	x64pb_wide_fields[0].kind = PB_KIND_INT64()
	x64pb_wide_fields[0].offset = cast(int, &m.a) - cast(int, &m)
	x64pb_wide_fields[0].aux = 0
	x64pb_wide_fields[1].number = 2
	x64pb_wide_fields[1].kind = PB_KIND_UINT64()
	x64pb_wide_fields[1].offset = cast(int, &m.b) - cast(int, &m)
	x64pb_wide_fields[1].aux = 0
	x64pb_wide_fields[2].number = 3
	x64pb_wide_fields[2].kind = PB_KIND_SINT64()
	x64pb_wide_fields[2].offset = cast(int, &m.c) - cast(int, &m)
	x64pb_wide_fields[2].aux = 0
	x64pb_wide_fields[3].number = 4
	x64pb_wide_fields[3].kind = PB_KIND_FIXED64()
	x64pb_wide_fields[3].offset = cast(int, &m.d) - cast(int, &m)
	x64pb_wide_fields[3].aux = 0
	x64pb_wide_desc.field_count = 4
	x64pb_wide_desc.fields = x64pb_wide_fields
	x64pb_wide_desc.struct_size = 32


void test_int64_kinds_roundtrip():
	x64pb_wide_desc_init()
	x64pb_wide_msg m
	m.a = -1
	m.b = 300
	int64 big = 1000000000
	big = big * 5
	m.c = 0 - big
	m.d = 2.5

	int out_len = 0
	char* out = pb_encode(&x64pb_wide_desc, cast(char*, &m), &out_len)

	char* buf = malloc(x64pb_wide_desc.struct_size)
	int i = 0
	while (i < x64pb_wide_desc.struct_size):
		buf[i] = 0
		i = i + 1
	wresult[char*]* r = pb_decode(&x64pb_wide_desc, out, out_len, buf)
	assert_equal(1, result_is_ok[char*](r))
	x64pb_wide_msg* decoded = cast(x64pb_wide_msg*, buf)
	assert_equal(1, decoded.a == -1)
	assert_equal(1, decoded.b == 300)
	assert_equal(1, decoded.c == m.c)
	assert_equal(1, decoded.d == 2.5)
	result_free[char*](r)
	free(out)
	free(buf)


# A genuine int64 field's negative value is ALREADY the full 64 bits --
# no further sign-extension step is needed (unlike a 32-bit int32
# field, which must be extended from 32 to 64 bits first): both produce
# the identical 10-byte wire encoding for -1, but for different reasons.
void test_int64_negative_wire_bytes():
	x64pb_wide_desc_init()
	x64pb_wide_msg m
	m.a = -1
	m.b = 0
	m.c = 0
	m.d = 0.0
	int out_len = 0
	char* out = pb_encode(&x64pb_wide_desc, cast(char*, &m), &out_len)
	x64pb_expect_bytes(c"int64(-1) wire bytes", out, out_len, c"\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", 11)
	free(out)


void test_uint64_large_value_wire_bytes():
	x64pb_wide_desc_init()
	x64pb_wide_msg m
	m.a = 0
	# 2^40 = 1099511627776: 6 varint groups (40 bits needs ceil(40/7)=6).
	int64 v = 1
	v = v << 40
	m.b = v
	m.c = 0
	m.d = 0.0
	int out_len = 0
	char* out = pb_encode(&x64pb_wide_desc, cast(char*, &m), &out_len)
	# tag(2,varint)=(2<<3)|0=16=0x10. 2^40's varint: bits 0-39 are all
	# zero except bit 40 itself, so every group up to the 6th is 0x80
	# (continuation, no payload bits set) and the 6th carries the one
	# surviving bit (2^40 >> 35 = 32 = 0x20, no continuation since it's
	# the last nonzero group).
	x64pb_expect_bytes(c"uint64(2^40) wire bytes", out, out_len, c"\x10\x80\x80\x80\x80\x80\x20", 7)
	free(out)


int main():
	test_zigzag64_native_pairs()
	test_int64_kinds_roundtrip()
	test_int64_negative_wire_bytes()
	test_uint64_large_value_wire_bytes()
	println(c"x64 protobuf wide-kind tests OK")
	return 0
