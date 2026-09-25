# wbuild: x64 expect_stdout="protobuf codegen tests OK"
/*
The .proto -> W generator (libs/extras/protobuf/codegen.w, issue #16
stage 2). tests/protobuf/sample_pb.w is the committed output for
tests/protobuf/sample.proto (proto_to_w_test regenerates and compares
it); this file compiles against it and round-trips messages through the
compiler's to_proto/from_proto, then drives the generator in-process for
its error paths.
*/
import lib.lib
import lib.assert
import lib.str
import libs.extras.protobuf.codegen
import tests.protobuf.sample_pb


void pbc_set(pb_bytes* b, char* s):
	b.data = s
	b.length = strlen(s)


void pbc_expect_bytes(char* label, pb_bytes* got, char* want, int want_len):
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


# Neither locals nor 'new' are zero-initialized, and to_proto encodes
# every field, so each message here comes from pb_message_new.
void test_generated_messages_round_trip():
	Address* home = cast(Address*, pb_message_new(proto_descriptor(Address)))
	pbc_set(&home.city, c"Oslo")
	home.zip = 150
	home.country = COUNTRY_NO

	Customer* customer = cast(Customer*, pb_message_new(proto_descriptor(Customer)))
	pbc_set(&customer.name, c"Ann")
	customer.avatar.data = c"\x00\x01"
	customer.avatar.length = 2
	customer.address = home
	customer.emails = new list[pb_bytes]
	pb_bytes email
	pbc_set(&email, c"a@b.c")
	customer.emails.push(email)

	Order* order = cast(Order*, pb_message_new(proto_descriptor(Order)))
	order.id = 7
	order.customer = customer
	order.items = new list[LineItem]
	LineItem* item = cast(LineItem*, pb_message_new(proto_descriptor(LineItem)))
	pbc_set(&item.sku, c"X1")
	item.quantity = 2
	item.gift = true
	item.adjustments = new list[int32]
	item.adjustments.push(-1)
	item.weight = 0.5
	item.offset = -7
	order.items.push(*item)
	order.status = Order_STATUS_SHIPPED
	order.tags = new list[Order_TagsEntry]
	Order_TagsEntry* tag = cast(Order_TagsEntry*, pb_message_new(proto_descriptor(Order_TagsEntry)))
	pbc_set(&tag.key, c"k")
	tag.value = 3
	order.tags.push(*tag)
	Order_Voucher* voucher = cast(Order_Voucher*, pb_message_new(proto_descriptor(Order_Voucher)))
	pbc_set(&voucher.code, c"V")
	voucher.discount = -5
	order.voucher = voucher
	pbc_set(&order.note, c"hi")
	Money* total = cast(Money*, pb_message_new(proto_descriptor(Money)))
	pbc_set(&total.currency, c"NOK")
	total.cents = 1250
	order.total = total
	Category* root = cast(Category*, pb_message_new(proto_descriptor(Category)))
	pbc_set(&root.name, c"root")
	Category* leaf = cast(Category*, pb_message_new(proto_descriptor(Category)))
	pbc_set(&leaf.name, c"leaf")
	leaf.parent = root
	leaf.children = new list[Category]
	Category* grandchild = cast(Category*, pb_message_new(proto_descriptor(Category)))
	pbc_set(&grandchild.name, c"gc")
	leaf.children.push(*grandchild)
	order.category = leaf

	pb_bytes* w = to_proto(order)
	Order* back = from_proto(Order, w)
	assert_equal(7, back.id)
	assert_strings_equal(c"Ann", back.customer.name.data)
	assert_equal(2, back.customer.avatar.length)
	assert_equal(1, back.customer.avatar.data[1])
	assert_strings_equal(c"Oslo", back.customer.address.city.data)
	assert_equal(150, back.customer.address.zip)
	assert_equal(COUNTRY_NO, back.customer.address.country)
	assert_strings_equal(c"a@b.c", back.customer.emails[0].data)
	assert_equal(1, back.items.length)
	assert_strings_equal(c"X1", back.items[0].sku.data)
	assert_equal(2, back.items[0].quantity)
	assert_equal(1, back.items[0].gift)
	assert_equal(-1, back.items[0].adjustments[0])
	assert_equal(Order_STATUS_SHIPPED, back.status)
	assert_strings_equal(c"k", back.tags[0].key.data)
	assert_equal(3, back.tags[0].value)
	assert_strings_equal(c"V", back.voucher.code.data)
	assert_equal(-5, back.voucher.discount)
	assert_equal(0, cast(int, back.card_token.data))
	assert_strings_equal(c"hi", back.note.data)
	assert_strings_equal(c"NOK", back.total.currency.data)
	assert_equal(1250, back.total.cents)
	assert_strings_equal(c"leaf", back.category.name.data)
	assert_strings_equal(c"root", back.category.parent.name.data)
	assert_strings_equal(c"gc", back.category.children[0].name.data)
	assert1(back.items[0].weight == 0.5)
	assert_equal(-7, back.items[0].offset)
	pb_free_message(proto_descriptor(Order), cast(char*, back))
	pb_bytes_free(w)


void test_map_entries_match_the_wire_format():
	# map<string, int32> tags = 5 with {"k": 3}: one length-delimited
	# field 5 holding an entry message {key = 1: "k", value = 2: 3}.
	Order* order = cast(Order*, pb_message_new(proto_descriptor(Order)))
	order.tags = new list[Order_TagsEntry]
	Order_TagsEntry* tag = cast(Order_TagsEntry*, pb_message_new(proto_descriptor(Order_TagsEntry)))
	pbc_set(&tag.key, c"k")
	tag.value = 3
	order.tags.push(*tag)
	pb_bytes* w = to_proto(order)
	pbc_expect_bytes(c"map entry", w, c"\x2a\x05\x0a\x01k\x10\x03", 7)
	pb_bytes_free(w)


char* pbc_generate(char* source):
	proto_codegen_result* r = proto_to_w(source, c"t.proto")
	return r.source


char* pbc_first_error(char* source):
	proto_codegen_result* r = proto_to_w(source, c"t.proto")
	assert_equal(0, cast(int, r.source))
	assert1(r.errors.length > 0)
	return r.errors[0]


void pbc_expect_contains(char* haystack, char* needle):
	if (index_of(haystack, needle) < 0):
		print2(c"expected to find: ")
		println2(needle)
		print2(c"in: ")
		println2(haystack)
		exit(1)


void test_mutually_recursive_messages():
	Ping* ping = cast(Ping*, pb_message_new(proto_descriptor(Ping)))
	Pong* pong = cast(Pong*, pb_message_new(proto_descriptor(Pong)))
	Ping* inner = cast(Ping*, pb_message_new(proto_descriptor(Ping)))
	pong.hops = 2
	pong.ping = inner
	ping.pong = pong
	pb_bytes* w = to_proto(ping)
	# ping{pong(1){ping(1){} hops(2)=2}}: the empty inner Ping still
	# encodes as a present, zero-length submessage.
	pbc_expect_bytes(c"ping", w, c"\x0a\x04\x0a\x00\x10\x02", 6)
	Ping* back = from_proto(Ping, w)
	assert_equal(2, back.pong.hops)
	assert1(back.pong.ping != 0)
	assert_equal(0, cast(int, back.pong.ping.pong))
	pb_free_message(proto_descriptor(Ping), cast(char*, back))
	pb_bytes_free(w)


void test_generator_output_shape():
	char* w = pbc_generate(c"syntax = \"proto3\";\nmessage A { B b = 1; }\nmessage B { int32 x = 1; }\n")
	assert1(w != 0)
	# B is declared before A even though the .proto lists it second.
	int a = index_of(w, c"message A:")
	int b = index_of(w, c"message B:")
	assert1((a >= 0) && (b >= 0))
	assert1(b < a)
	pbc_expect_contains(w, c"\tB b = 1\n")
	pbc_expect_contains(w, c"import libs.extras.protobuf.message\n")

	# A cycle gets one forward declaration; a self reference needs none.
	char* cyc = pbc_generate(c"message A { B b = 1; A self = 2; }\nmessage B { A a = 1; double d = 2; }\n")
	assert1(cyc != 0)
	pbc_expect_contains(cyc, c"\nmessage A\n")
	pbc_expect_contains(cyc, c"\tA self = 2\n")
	pbc_expect_contains(cyc, c"\tdouble d = 2\n")


void test_generator_errors():
	pbc_expect_contains(pbc_first_error(c"message A {\n  Missing m = 1;\n}"), c"t.proto:2: unknown type 'Missing'")
	pbc_expect_contains(pbc_first_error(c"import \"no/such.proto\";\nmessage A { int32 x = 1; }"), c"t.proto:1: cannot find imported file 'no/such.proto'")
	pbc_expect_contains(pbc_first_error(c"message A { int32 x = 0; }"), c"field number must be between 1 and 536870911")
	pbc_expect_contains(pbc_first_error(c"enum E { NEG = -1; }"), c"negative enum values are not supported yet")
	pbc_expect_contains(pbc_first_error(c"message A { int32 x = 1 }"), c"t.proto:1: syntax error")


int main():
	test_generated_messages_round_trip()
	test_map_entries_match_the_wire_format()
	test_mutually_recursive_messages()
	test_generator_output_shape()
	test_generator_errors()
	println(c"protobuf codegen tests OK")
	return 0
