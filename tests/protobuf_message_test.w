# wbuild: x64 arch=wasm expect_stdout="protobuf message tests OK"
/*
The 'message' declaration and the to_proto/from_proto/proto_descriptor
builtins (grammar/protobuf_builtin.w; issue #16 stage 3,
docs/projects/protobuf.md §9). The compiler emits each message's
descriptor and the stage-1 runtime (libs/extras/protobuf/message.w)
does the wire work, so these tests pin the compiler side: storage
types, field numbers, the emitted descriptor (checked via golden wire
bytes, several from Google's protobuf "Encoding" guide), and the
builtins' lowering. Wide 64-bit kinds live in
tests/protobuf_message_x64_test.w (int64/uint64 are 64-bit-word-only).
*/
import lib.lib
import lib.assert
import lib.result
import libs.extras.protobuf.message


void pbm_expect_bytes(char* label, pb_bytes* got, char* want, int want_len):
	if (got.length != want_len):
		print2(label)
		print2(c": length mismatch got=")
		print2(itoa(got.length))
		print2(c" want=")
		println2(itoa(want_len))
		exit(1)
	for i in range(want_len):
		if ((got.data[i] & 255) != (want[i] & 255)):
			print2(label)
			print2(c": byte mismatch at offset ")
			println2(itoa(i))
			exit(1)


void pbm_set(pb_bytes* b, char* s):
	b.data = s
	b.length = strlen(s)


# Google's Encoding-guide messages: Test1 { int32 a = 1 },
# Test2 { string b = 2 }, Test3 { Test1 c = 3 },
# Test4 { string d = 1; repeated int32 e = 4 }.
message Test1:
	int32 a = 1


message Test2:
	string b = 2


message Test3:
	Test1 c = 3


message Test4:
	string d = 1
	repeated int32 e = 4


enum pbm_color:
	pbm_red
	pbm_green
	pbm_blue


# Declared out of wire-number order on purpose: encode follows field
# numbers, not declaration order.
message pbm_person:
	bool active = 4
	string name = 1
	sint32 delta = 3
	int32 id = 2
	pbm_color color = 7
	uint32 count = 8
	fixed32 tag = 9
	bytes blob = 10
	repeated string aliases = 11
	repeated bool flags = 12
	repeated Test1 items = 13


message pbm_empty:
	int32 unused = 1


void test_guide_vectors():
	Test1 t1
	t1.a = 150
	pb_bytes* w = to_proto(t1)
	pbm_expect_bytes(c"Test1", w, c"\x08\x96\x01", 3)
	Test1* back = from_proto(Test1, w)
	assert_equal(150, back.a)
	pb_free_message(proto_descriptor(Test1), cast(char*, back))
	pb_bytes_free(w)

	Test2 t2
	pbm_set(&t2.b, c"testing")
	Test2* t2p = &t2
	w = to_proto(t2p)
	pbm_expect_bytes(c"Test2", w, c"\x12\x07testing", 9)
	Test2* back2 = from_proto(Test2, w)
	assert_equal(7, back2.b.length)
	assert_strings_equal(c"testing", back2.b.data)
	pb_free_message(proto_descriptor(Test2), cast(char*, back2))
	pb_bytes_free(w)

	Test3 t3
	t3.c = &t1
	w = to_proto(t3)
	pbm_expect_bytes(c"Test3", w, c"\x1a\x03\x08\x96\x01", 5)
	Test3* back3 = from_proto(Test3, w)
	assert_equal(150, back3.c.a)
	pb_free_message(proto_descriptor(Test3), cast(char*, back3))
	pb_bytes_free(w)

	Test4 t4
	pbm_set(&t4.d, c"hello")
	t4.e = new list[int32]
	t4.e.push(1)
	t4.e.push(2)
	t4.e.push(3)
	w = to_proto(t4)
	pbm_expect_bytes(c"Test4", w, c"\x0a\x05hello\x22\x03\x01\x02\x03", 12)
	Test4* back4 = from_proto(Test4, w)
	assert_equal(3, back4.e.length)
	assert_equal(3, back4.e[2])
	pb_free_message(proto_descriptor(Test4), cast(char*, back4))
	pb_bytes_free(w)


void test_negative_int32_is_ten_bytes():
	# proto3 sign-extends a negative int32 to 64 bits before varint
	# encoding, so -1 always takes ten payload bytes.
	Test1 t1
	t1.a = -1
	pb_bytes* w = to_proto(t1)
	pbm_expect_bytes(c"Test1 -1", w, c"\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", 11)
	Test1* back = from_proto(Test1, w)
	assert_equal(-1, back.a)
	pb_free_message(proto_descriptor(Test1), cast(char*, back))
	pb_bytes_free(w)


void test_zero_values_are_omitted():
	Test1 t1
	t1.a = 0
	pb_bytes* w = to_proto(t1)
	assert_equal(0, w.length)
	Test1* back = from_proto(Test1, w)
	assert_equal(0, back.a)
	pb_free_message(proto_descriptor(Test1), cast(char*, back))
	pb_bytes_free(w)


pbm_person* pbm_person_new():
	pbm_person* p = new pbm_person
	pbm_set(&p.name, c"Ann")
	p.id = 150
	p.delta = -2
	p.active = true
	p.color = pbm_blue
	p.count = 7
	p.tag = 1
	p.blob.data = c"a\x00b"
	p.blob.length = 3
	p.aliases = new list[pb_bytes]
	pb_bytes alias
	pbm_set(&alias, c"x")
	p.aliases.push(alias)
	pbm_set(&alias, c"yz")
	p.aliases.push(alias)
	p.flags = new list[bool]
	p.flags.push(true)
	p.flags.push(false)
	p.flags.push(true)
	p.items = new list[Test1]
	Test1 item
	item.a = 5
	p.items.push(item)
	item.a = 300
	p.items.push(item)
	return p


void test_field_order_and_kinds():
	pbm_person* p = pbm_person_new()
	pb_bytes* w = to_proto(p)
	# name=1 "Ann", id=2 150, delta=3 sint32 -2 (zigzag 3), active=4,
	# color=7 enum 2, count=8 7, tag=9 fixed32 1, blob=10 "a\0b",
	# aliases=11 "x" "yz" (one field each), flags=12 packed 1 0 1,
	# items=13 {a=5} {a=300} (one field each).
	char* want = c"\x0a\x03Ann\x10\x96\x01\x18\x03\x20\x01\x38\x02\x40\x07\x4d\x01\x00\x00\x00\x52\x03a\x00b\x5a\x01x\x5a\x02yz\x62\x03\x01\x00\x01\x6a\x02\x08\x05\x6a\x03\x08\xac\x02"
	pbm_expect_bytes(c"pbm_person", w, want, 47)

	pbm_person* q = from_proto(pbm_person, w)
	assert_strings_equal(c"Ann", q.name.data)
	assert_equal(150, q.id)
	assert_equal(-2, q.delta)
	assert_equal(1, q.active)
	assert_equal(pbm_blue, q.color)
	assert_equal(7, q.count)
	assert_equal(1, q.tag)
	assert_equal(3, q.blob.length)
	assert_equal(0, q.blob.data[1])
	assert_equal('b', q.blob.data[2])
	assert_equal(2, q.aliases.length)
	assert_strings_equal(c"yz", q.aliases[1].data)
	assert_equal(3, q.flags.length)
	assert_equal(1, q.flags[0])
	assert_equal(0, q.flags[1])
	assert_equal(1, q.flags[2])
	assert_equal(2, q.items.length)
	assert_equal(5, q.items[0].a)
	assert_equal(300, q.items[1].a)

	# Byte-identical re-encode of our own output (canonical encoding).
	pb_bytes* w2 = to_proto(q)
	pbm_expect_bytes(c"pbm_person re-encode", w2, want, 47)
	pb_bytes_free(w2)
	pb_free_message(proto_descriptor(pbm_person), cast(char*, q))
	pb_bytes_free(w)


# A singular bool decodes into its one byte only: the neighbouring
# field must survive (the runtime's BOOL element width is 4 bytes).
message pbm_bool_neighbour:
	bool flag = 1
	fixed32 after = 2


void test_bool_does_not_clobber_neighbour():
	pbm_bool_neighbour* q = from_proto(pbm_bool_neighbour, c"\x15\x44\x33\x22\x11\x08\x01", 7)
	assert_equal(1, q.flag)
	assert_equal_hex(0x11223344, q.after)
	pb_free_message(proto_descriptor(pbm_bool_neighbour), cast(char*, q))


void test_unknown_fields_are_skipped():
	# field 5 varint, field 6 fixed64, field 7 string, then a=1 150
	char* data = c"\x28\x01\x31\x01\x02\x03\x04\x05\x06\x07\x08\x3a\x02hi\x08\x96\x01"
	Test1* back = from_proto(Test1, data, 18)
	assert_equal(150, back.a)
	pb_free_message(proto_descriptor(Test1), cast(char*, back))


void test_malformed_input_decodes_to_null():
	# truncated varint
	Test1* back = from_proto(Test1, c"\x08\x96", 2)
	assert_equal(0, cast(int, back))
	# length overrun
	Test2* back2 = from_proto(Test2, c"\x12\x09abc", 5)
	assert_equal(0, cast(int, back2))
	# null pb_bytes*
	pb_bytes* none = cast(pb_bytes*, 0)
	Test1* back3 = from_proto(Test1, none)
	assert_equal(0, cast(int, back3))


void test_descriptor_and_wresult_api():
	pb_message_desc* d = proto_descriptor(pbm_person)
	assert_equal(11, d.field_count)
	# Fields are sorted by wire number.
	assert_equal(1, d.fields[0].number)
	assert_equal(PB_KIND_STRING, d.fields[0].kind)
	assert_equal(13, d.fields[10].number)
	assert_equal(PB_KIND_REPEATED, d.fields[10].kind)
	assert_equal(0, d.struct_size % __word_size__)
	# The same descriptor blob is reused per type.
	assert_equal(cast(int, d), cast(int, proto_descriptor(pbm_person)))

	pb_message_desc* d1 = proto_descriptor(Test1)
	char* buf = malloc(d1.struct_size)
	for i in range(d1.struct_size): buf[i] = 0
	wresult[char*]* r = pb_decode(d1, c"\x08", 1, buf)
	assert_equal(0, result_is_ok[char*](r))
	assert_equal(PB_ERR_TRUNCATED, result_code[char*](r))
	result_free[char*](r)
	free(buf)


# Recursive messages: a self reference needs nothing extra; two
# messages that refer to each other need a forward declaration.
message pbm_tree:
	int32 value = 1
	pbm_tree parent = 2
	repeated pbm_tree children = 3


message pbm_pong


message pbm_ping:
	pbm_pong pong = 1
	float ratio = 2
	sfixed32 delta = 3


message pbm_pong:
	pbm_ping ping = 1
	int32 hops = 2


void test_recursive_messages_and_float():
	pbm_tree* root = cast(pbm_tree*, pb_message_new(proto_descriptor(pbm_tree)))
	root.value = 1
	root.children = new list[pbm_tree]
	pbm_tree* child = cast(pbm_tree*, pb_message_new(proto_descriptor(pbm_tree)))
	child.value = 2
	root.children.push(*child)
	pbm_tree* up = cast(pbm_tree*, pb_message_new(proto_descriptor(pbm_tree)))
	up.value = 7
	root.parent = up
	pb_bytes* w = to_proto(root)
	pbm_tree* back = from_proto(pbm_tree, w)
	assert_equal(1, back.value)
	assert_equal(7, back.parent.value)
	assert_equal(2, back.children[0].value)
	pb_free_message(proto_descriptor(pbm_tree), cast(char*, back))
	pb_bytes_free(w)

	pbm_ping* ping = cast(pbm_ping*, pb_message_new(proto_descriptor(pbm_ping)))
	pbm_pong* pong = cast(pbm_pong*, pb_message_new(proto_descriptor(pbm_pong)))
	pong.hops = 3
	ping.pong = pong
	ping.ratio = 1.5
	ping.delta = -1
	w = to_proto(ping)
	# pong(1){hops=3}, ratio(2) float 1.5 = 00 00 c0 3f,
	# delta(3) sfixed32 -1 = ff ff ff ff.
	pbm_expect_bytes(c"pbm_ping", w, c"\x0a\x02\x10\x03\x15\x00\x00\xc0\x3f\x1d\xff\xff\xff\xff", 14)
	pbm_ping* pback = from_proto(pbm_ping, w)
	assert_equal(3, pback.pong.hops)
	assert1(pback.ratio == 1.5)
	assert_equal(-1, pback.delta)
	pb_free_message(proto_descriptor(pbm_ping), cast(char*, pback))
	pb_bytes_free(w)


void test_empty_message():
	pbm_empty e
	e.unused = 0
	pb_bytes* w = to_proto(e)
	assert_equal(0, w.length)
	pbm_empty* back = from_proto(pbm_empty, w)
	assert_equal(0, back.unused)
	pb_free_message(proto_descriptor(pbm_empty), cast(char*, back))
	pb_bytes_free(w)


# 'message' stays an ordinary identifier outside the top-level
# 'message Name:' declaration shape.
int message_count


int pbm_message_len(char* message):
	int n = strlen(message)
	return n


void test_message_is_still_an_identifier():
	char* message = c"hi"
	message_count = pbm_message_len(message)
	assert_equal(2, message_count)


int main():
	test_message_is_still_an_identifier()
	test_guide_vectors()
	test_negative_int32_is_ten_bytes()
	test_zero_values_are_omitted()
	test_field_order_and_kinds()
	test_bool_does_not_clobber_neighbour()
	test_unknown_fields_are_skipped()
	test_malformed_input_decodes_to_null()
	test_descriptor_and_wresult_api()
	test_recursive_messages_and_float()
	test_empty_message()
	println(c"protobuf message tests OK")
	return 0
