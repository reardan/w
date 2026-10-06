# wbuild: x64
# Struct stores whose size is not a word multiple (#524). The copy used
# to move ceil(size / word) whole words, so the bytes after the
# destination were overwritten with whatever followed the source. Each
# store below is surrounded by sentinels that must survive, for field,
# array element, pointer, heap, declaration, by-value argument and
# return-value copies, with sizes 1, 2, 3, 5, 6, 7 and (x64) 9..15.
import lib.testing


struct one:
	int8 a


struct three:
	int8 a
	int8 b
	int8 c


struct six:
	int16 a
	int16 b
	int16 c


struct seven:
	int8 a
	int16 b
	int32 c


struct eleven:
	int32 a
	int32 b
	int16 c
	int8 d


struct holder1:
	int before
	one value
	int8 tail1
	int8 tail2
	int8 tail3
	int after


struct holder7:
	int before
	seven value
	int8 tail
	int after


struct holder11:
	int before
	eleven value
	int8 tail
	int after


one make_one(int a):
	one o
	o.a = a
	return o


seven make_seven(int a, int b, int c):
	seven s
	s.a = a
	s.b = b
	s.c = c
	return s


eleven make_eleven(int a, int b, int c, int d):
	eleven e
	e.a = a
	e.b = b
	e.c = c
	e.d = d
	return e


int seven_sum(seven s):
	return s.a + s.b + s.c


void test_sizes():
	assert_equal(1, sizeof(one))
	assert_equal(3, sizeof(three))
	assert_equal(6, sizeof(six))
	assert_equal(7, sizeof(seven))
	assert_equal(11, sizeof(eleven))


void test_field_store_one():
	holder1 h
	h.before = 0x1234567
	h.tail1 = 0x11
	h.tail2 = 0x22
	h.tail3 = 0x33
	h.after = 0x7654321
	one src
	src.a = 0x5a
	h.value = src
	assert_equal_hex(0x5a, h.value.a)
	assert_equal_hex(0x11, h.tail1)
	assert_equal_hex(0x22, h.tail2)
	assert_equal_hex(0x33, h.tail3)
	assert_equal_hex(0x1234567, h.before)
	assert_equal_hex(0x7654321, h.after)
	h.value = make_one(0x3c)
	assert_equal_hex(0x3c, h.value.a)
	assert_equal_hex(0x11, h.tail1)
	assert_equal_hex(0x22, h.tail2)
	assert_equal_hex(0x33, h.tail3)


void test_field_store_seven():
	holder7 h
	h.before = 0x1234567
	h.tail = 0x44
	h.after = 0x7654321
	seven src = make_seven(1, 2, 3)
	h.value = src
	assert_equal(1, h.value.a)
	assert_equal(2, h.value.b)
	assert_equal(3, h.value.c)
	assert_equal_hex(0x44, h.tail)
	assert_equal_hex(0x1234567, h.before)
	assert_equal_hex(0x7654321, h.after)


void test_field_store_eleven():
	holder11 h
	h.before = 0x1234567
	h.tail = 0x55
	h.after = 0x7654321
	h.value = make_eleven(10, 20, 30, 40)
	assert_equal(10, h.value.a)
	assert_equal(20, h.value.b)
	assert_equal(30, h.value.c)
	assert_equal(40, h.value.d)
	assert_equal_hex(0x55, h.tail)
	assert_equal_hex(0x1234567, h.before)
	assert_equal_hex(0x7654321, h.after)


void test_array_store_one():
	one[4] tiny
	for i in range(4): tiny[i].a = 0x10 + i
	one src
	src.a = 0x7e
	tiny[0] = src
	assert_equal_hex(0x7e, tiny[0].a)
	assert_equal_hex(0x11, tiny[1].a)
	assert_equal_hex(0x12, tiny[2].a)
	assert_equal_hex(0x13, tiny[3].a)
	tiny[2] = src
	assert_equal_hex(0x11, tiny[1].a)
	assert_equal_hex(0x7e, tiny[2].a)
	assert_equal_hex(0x13, tiny[3].a)


void test_array_store_three():
	three[3] arr
	for i in range(3):
		arr[i].a = i * 3
		arr[i].b = i * 3 + 1
		arr[i].c = i * 3 + 2
	three src
	src.a = 100
	src.b = 101
	src.c = 102
	arr[1] = src
	assert_equal(0, arr[0].a)
	assert_equal(2, arr[0].c)
	assert_equal(100, arr[1].a)
	assert_equal(102, arr[1].c)
	assert_equal(6, arr[2].a)
	assert_equal(7, arr[2].b)
	assert_equal(8, arr[2].c)


void test_pointer_store_six():
	char* raw = cast(char*, malloc(32))
	for i in range(32): raw[i] = 0x66
	six* p = cast(six*, &raw[8])
	six src
	src.a = 1
	src.b = 2
	src.c = 3
	*p = src
	assert_equal(1, p.a)
	assert_equal(2, p.b)
	assert_equal(3, p.c)
	for i in range(8): assert_equal_hex(0x66, raw[i])
	for i in range(14, 32): assert_equal_hex(0x66, raw[i])


void test_heap_store_seven():
	char* raw = cast(char*, malloc(48))
	for i in range(48): raw[i] = 0x77
	seven* p = cast(seven*, &raw[16])
	p[0] = make_seven(4, 5, 6)
	assert_equal(15, seven_sum(p[0]))
	for i in range(16): assert_equal_hex(0x77, raw[i])
	for i in range(23, 48): assert_equal_hex(0x77, raw[i])
	eleven* q = cast(eleven*, &raw[24])
	*q = make_eleven(1, 2, 3, 4)
	assert_equal(4, q.d)
	for i in range(35, 48): assert_equal_hex(0x77, raw[i])
	# the seven before it is untouched
	assert_equal(15, seven_sum(p[0]))


void test_new_struct_copy():
	seven* s = new seven()
	seven src = make_seven(7, 8, 9)
	*s = src
	assert_equal(24, seven_sum(*s))
