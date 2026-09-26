# wbuild: arch_only=x64 expect_stdout="protobuf message x64 tests OK"
/*
The message keyword's 64-bit field kinds (int64, sint64, uint64,
fixed64, sfixed64, double), which store as int64/uint64 and so exist only on 8-byte-word
targets (grammar/protobuf_builtin.w; the 32-bit target rejects them,
see tests/protobuf_message_wide_error_fixture.w). Companion to
tests/protobuf_message_test.w.
*/
import lib.lib
import lib.assert
import libs.extras.protobuf.message


message pbw_wide:
	int64 a = 1
	sint64 b = 2
	uint64 c = 3
	fixed64 d = 4
	repeated sint64 e = 5
	double f = 6
	sfixed64 g = 7


void pbw_expect_bytes(char* label, pb_bytes* got, char* want, int want_len):
	if (got.length != want_len):
		print2(label)
		print2(c": length mismatch got=")
		println2(itoa(got.length))
		exit(1)
	for i in range(want_len):
		if ((got.data[i] & 255) != (want[i] & 255)):
			print2(label)
			print2(c": byte mismatch at offset ")
			println2(itoa(i))
			exit(1)


int main():
	pbw_wide m
	m.a = -2
	m.b = -2
	uint64 one = 1
	m.c = one << 32
	m.d = 1
	m.e = new list[int64]
	m.e.push(-1)
	m.e.push(1)
	m.f = 0.0
	m.g = 0
	pb_bytes* w = to_proto(m)
	# a=1: -2 sign-extended, ten bytes; b=2: zigzag(-2)=3;
	# c=3: 2^32 = 80 80 80 80 10; d=4: eight raw bytes;
	# e=5: packed zigzag [1, 2].
	char* want = c"\x08\xfe\xff\xff\xff\xff\xff\xff\xff\xff\x01\x10\x03\x18\x80\x80\x80\x80\x10\x21\x01\x00\x00\x00\x00\x00\x00\x00\x2a\x02\x01\x02"
	pbw_expect_bytes(c"pbw_wide", w, want, 32)
	pb_bytes_free(w)

	# f=6: double 1.0 is 00..f0 3f; g=7: sfixed64 -2 is fe ff .. ff.
	m.f = 1.0
	m.g = -2
	w = to_proto(m)
	char* tail = c"\x31\x00\x00\x00\x00\x00\x00\xf0\x3f\x39\xfe\xff\xff\xff\xff\xff\xff\xff"
	for i in range(18): assert_equal(tail[i] & 255, w.data[32 + i] & 255)
	assert_equal(50, w.length)
	pbw_wide* q = from_proto(pbw_wide, w)
	assert1(q.a == -2)
	assert1(q.b == -2)
	assert1(q.c == (one << 32))
	assert1(q.d == 1)
	assert_equal(2, q.e.length)
	assert1(q.e[0] == -1)
	assert1(q.e[1] == 1)
	assert1(q.f == 1.0)
	assert1(q.g == -2)
	pb_free_message(proto_descriptor(pbw_wide), cast(char*, q))
	pb_bytes_free(w)
	println(c"protobuf message x64 tests OK")
	return 0
