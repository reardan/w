# wbuild: x64
# Local-slot load fusion semantics, pinning the contract in
# code_generator/x86.w (docs/projects/optimization.md's v0 window): a
# local or argument read folds its 'lea eax,[esp+N]' into the load that
# follows ('mov eax,[esp+N]', and the sign/zero-extending byte, short and
# int32 forms), a constant member offset folds into the lea, adding zero
# emits nothing, a binary operator whose right operand is one simple
# instruction moves the left operand to ebx instead of pushing it, and a
# shift by a constant uses the immediate form. None of that may change
# what a program computes: every width must extend exactly as the plain
# load through a pointer does, displacements past the disp8 range must
# still address the right slot, and a jump target between the folded
# instructions must not be rewritten away (the ternary cases).
import lib.assert

struct fold_pair:
	int first
	int second

struct fold_mixed:
	int8 tag
	int16 half
	int32 word
	uint8 ubyte
	uint16 uhalf
	uint32 uword

struct fold_outer:
	fold_pair inner
	int tail


int identity(int v):
	return v


void test_widths():
	int8 i8 = -5
	uint8 u8 = 250
	int16 i16 = -300
	uint16 u16 = 65000
	int32 i32 = -70000
	uint32 u32 = 4000000000
	char c = 'z'
	bool b = true
	int w = -123456
	# The folded direct loads must extend exactly like the plain load
	# through a pointer.
	int8* p8 = &i8
	uint8* pu8 = &u8
	int16* p16 = &i16
	uint16* pu16 = &u16
	int32* p32 = &i32
	uint32* pu32 = &u32
	assert_equal(-5, i8)
	assert_equal(*p8, i8)
	assert_equal(250, u8)
	assert_equal(*pu8, u8)
	assert_equal(-300, i16)
	assert_equal(*p16, i16)
	assert_equal(65000, u16)
	assert_equal(*pu16, u16)
	assert_equal(-70000, i32)
	assert_equal(*p32, i32)
	assert_equal(*pu32, u32)
	assert_equal('z', c)
	assert_equal(1, b)
	assert_equal(-123456, w)
	# Narrow values as right operands of the register shuttle
	assert_equal(-10, i8 + i8)
	assert_equal(255, u8 - i8)
	assert_equal(-295, i16 - i8)
	assert_equal(1, i16 < u16)
	assert_equal(-69700, i32 - i16)


void test_arguments(int a, int b, int8 n, uint16 m):
	assert_equal(7, a)
	assert_equal(-3, b)
	assert_equal(-1, n)
	assert_equal(65535, m)
	assert_equal(4, a + b)
	assert_equal(10, a - b)
	assert_equal(-10, b - a)
	assert_equal(-21, a * b)
	assert_equal(-2, a / b)
	assert_equal(1, a % b)
	assert_equal(1, b < a)
	assert_equal(0, a < b)
	assert_equal(-8, b + n * 5)
	assert_equal(65536, m - n)


# A frame larger than the disp8 range: locals declared before the array
# sit more than 127 bytes above esp, the ones after it close to esp.
void test_large_frame():
	int before = 11
	int8 before8 = -7
	int[80] big
	int i = 0
	while (i < 80):
		big[i] = i * 3
		i = i + 1
	int after = 13
	uint16 after16 = 60000
	assert_equal(11, before)
	assert_equal(-7, before8)
	assert_equal(13, after)
	assert_equal(60000, after16)
	assert_equal(24, before + after)
	assert_equal(2, after - before)
	assert_equal(-2, before - after)
	assert_equal(4, before8 + before)
	assert_equal(60013, after16 + after)
	assert_equal(237, big[79])
	int sum = 0
	i = 0
	while (i < 80):
		sum = sum + big[i]
		i = i + 1
	assert_equal(9480, sum)


void test_struct_fields():
	fold_pair p
	p.first = -41
	p.second = 42
	assert_equal(-41, p.first)
	assert_equal(42, p.second)
	assert_equal(1, p.first + p.second)
	assert_equal(83, p.second - p.first)
	fold_mixed m
	m.tag = -2
	m.half = -1000
	m.word = -100000
	m.ubyte = 200
	m.uhalf = 50000
	m.uword = 3000000000
	assert_equal(-2, m.tag)
	assert_equal(-1000, m.half)
	assert_equal(-100000, m.word)
	assert_equal(200, m.ubyte)
	assert_equal(50000, m.uhalf)
	uint32* uw = &m.uword
	assert_equal(*uw, m.uword)
	assert_equal(198, m.tag + m.ubyte)
	fold_outer o
	o.inner.first = 5
	o.inner.second = 6
	o.tail = 7
	assert_equal(5, o.inner.first)
	assert_equal(6, o.inner.second)
	assert_equal(7, o.tail)
	assert_equal(18, o.inner.first + o.inner.second + o.tail)
	# Through a pointer: offset 0 and a nonzero offset
	fold_pair* pp = &p
	assert_equal(-41, pp.first)
	assert_equal(42, pp.second)
	pp.first = 9
	assert_equal(9, p.first)


void bump(int* slot):
	*slot = *slot + 1


void test_address_of():
	int a = 5
	int b = 6
	int* pa = &a
	*pa = 50
	assert_equal(50, a)
	bump(&b)
	bump(&b)
	assert_equal(8, b)
	assert_equal(58, a + b)
	char[4] buf
	buf[0] = 'h'
	buf[1] = 0
	char* s = buf
	assert_equal('h', s[0])


void test_shifts():
	int x = -1000
	int y = 1000
	int k1 = 1
	int k3 = 3
	int k31 = 31
	int k33 = 33
	# Literal counts (the immediate form) against variable counts (the cl
	# form): sar keeps the sign, shl, and the hardware count masking.
	assert_equal(x >> k3, x >> 3)
	assert_equal(-125, x >> 3)
	assert_equal(125, y >> 3)
	assert_equal(x << k3, x << 3)
	assert_equal(-8000, x << 3)
	assert_equal(y >> k31, y >> 31)
	assert_equal(x >> k31, x >> 31)
	assert_equal(-1, x >> 31)
	assert_equal(y << k33, y << 33)
	assert_equal(x >> k33, x >> 33)
	assert_equal(y << k1, y << 1)
	assert_equal(y, y << 0)
	assert_equal(x, x >> 0)
	uint32 u = 4000000000
	assert_equal(u >> k3, u >> 3)
	assert_equal(u << k1, u << 1)
	uint8 small = 200
	assert_equal(100, small >> 1)
	assert_equal(small >> k1, small >> 1)
	int8 neg8 = -128
	assert_equal(-64, neg8 >> 1)
	# The logical shift builtin: shr zero-fills where >> sign-fills
	assert_equal(shr(x, k3), shr(x, 3))
	assert_equal(0x1fffff83, shr(x, 3))
	assert_equal(1, shr(x, 31))
	# Constant on both sides, and a side-effecting left operand
	assert_equal(40, 5 << 3)
	assert_equal(-4, -32 >> 3)
	assert_equal(48, identity(6) << 3)
	assert_equal(-2, identity(-16) >> 3)


# A merge point between the last instruction of a branch and the operator
# that follows: nothing may fold back across it.
void test_merge_points(int c):
	int a = 10
	int b = 20
	int want_add = 5
	int want_first = b
	int want_lt = 0
	if (c):
		want_add = 4
		want_first = a
		want_lt = 1
	assert_equal(want_add, (c ? 1 : 2) + 3)
	assert_equal(want_first, *(c ? &a : &b))
	assert_equal(want_first + 1, (c ? a : b) + 1)
	assert_equal(want_first << 2, (c ? a : b) << 2)
	int r = 0
	if (c ? (a < b) : (a > b)): r = 1
	assert_equal(want_lt, r)
	fold_pair p
	p.first = a
	p.second = b
	fold_pair q
	q.first = b
	q.second = a
	fold_pair* pick = c ? &p : &q
	assert_equal(want_first, pick.first)


void test_loops():
	int n = 0
	int total = 0
	while (n < 10):
		total = total + n
		n = n + 1
	assert_equal(45, total)
	int acc = 1
	for i in range(5): acc = acc * 2 + i
	assert_equal(58, acc)


int main():
	test_widths()
	test_arguments(7, -3, -1, 65535)
	test_large_frame()
	test_struct_fields()
	test_address_of()
	test_shifts()
	test_merge_points(1)
	test_merge_points(0)
	test_loops()
	println2(c"local_load_fold_test OK")
	return 0
