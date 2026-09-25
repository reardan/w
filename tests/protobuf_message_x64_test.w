# wbuild: arch_only=x64 expect_stdout="protobuf message x64 tests OK"
/*
The message keyword's 64-bit field kinds (int64, sint64, uint64,
fixed64), which store as int64/uint64 and so exist only on 8-byte-word
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


void pbw_expect_bytes(char* label, pb_bytes* got, char* want, int want_len):
	if (got.length != want_len):
		print2(label)
		print2(c": length mismatch got=")
		println2(itoa(got.length))
		exit(1)
	int i = 0
	while (i < want_len):
		if ((got.data[i] & 255) != (want[i] & 255)):
			print2(label)
			print2(c": byte mismatch at offset ")
			println2(itoa(i))
			exit(1)
		i = i + 1


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
	pb_bytes* w = to_proto(m)
	# a=1: -2 sign-extended, ten bytes; b=2: zigzag(-2)=3;
	# c=3: 2^32 = 80 80 80 80 10; d=4: eight raw bytes;
	# e=5: packed zigzag [1, 2].
	char* want = c"\x08\xfe\xff\xff\xff\xff\xff\xff\xff\xff\x01\x10\x03\x18\x80\x80\x80\x80\x10\x21\x01\x00\x00\x00\x00\x00\x00\x00\x2a\x02\x01\x02"
	pbw_expect_bytes(c"pbw_wide", w, want, 32)
	pbw_wide* q = from_proto(pbw_wide, w)
	assert1(q.a == -2)
	assert1(q.b == -2)
	assert1(q.c == (one << 32))
	assert1(q.d == 1)
	assert_equal(2, q.e.length)
	assert1(q.e[0] == -1)
	assert1(q.e[1] == 1)
	pb_free_message(proto_descriptor(pbw_wide), cast(char*, q))
	pb_bytes_free(w)
	println(c"protobuf message x64 tests OK")
	return 0
