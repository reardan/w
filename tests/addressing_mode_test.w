# wbuild: x64
# wbuild: step="bin/wv2 --no-regs tests/addressing_mode_test.w -o bin/addressing_mode_noregs_test"
# wbuild: step="bin/addressing_mode_noregs_test"
# wbuild: step="bin/wv2 x64 --no-regs tests/addressing_mode_test.w -o bin/addressing_mode_noregs_64_test"
# wbuild: step="bin/addressing_mode_noregs_64_test"
# wbuild: step="bin/wv2 --no-addr-modes tests/addressing_mode_test.w -o bin/addressing_mode_noaddr_test"
# wbuild: step="bin/addressing_mode_noaddr_test"
# wbuild: step="bin/wv2 x64 --no-addr-modes tests/addressing_mode_test.w -o bin/addressing_mode_noaddr_64_test"
# wbuild: step="bin/addressing_mode_noaddr_64_test"
# Addressing modes (docs/projects/codegen_gap_plan.md §2.2, unit A2;
# code_generator/x86.w, the address note): a subscript or a field access
# becomes one [base+index*scale+disp] memory operand on the load or
# store that consumes it, when the base and the index are registers, a
# constant, or the accumulator. Every element width, every SIB scale and
# the scales that need a shift or a multiply, constant, register, 'R +/-
# c' and computed indices, negative and disp32 displacements, bases on
# the stack and in registers (callee-saved and loop-owned), field reads
# and writes through promoted and stack-resident pointers, chains
# ('p.a[i]', 'a[i].f', 'a[i].inner.b'), element and field addresses,
# plain, compound and increment stores on elements, fields and stack
# locals, compares of every width against constants, folded negated
# constants, and the left-side-first
# evaluation order of a store whose right side writes the base or the
# index. Every expected value is written out by hand; the test runs
# again with --no-regs (no register bases) and with --no-addr-modes (no
# folds at all) on both widths, and regalloc_diff_test sweeps it too.
import lib.lib
import lib.assert


struct pair:
	int a
	int b


struct triple:
	int a
	int b
	int c


struct widths:
	int8 i8
	uint8 u8
	int16 i16
	uint16 u16
	int32 i32
	uint32 u32
	int w
	float32 f32
	int* p


struct box:
	pair inner
	int tag
	int pad


struct cursor:
	int status
	int bit_pos
	char* data
	int count


# --- every element width, register and constant indices ----------------
int8* new_i8(int n):
	int8* a = cast(int8*, malloc(n))
	for i in range(n): a[i] = i - 100
	return a


int widths_sum(int n):
	int8* i8 = cast(int8*, malloc(n))
	uint8* u8 = cast(uint8*, malloc(n))
	int16* i16 = cast(int16*, malloc(n * 2))
	uint16* u16 = cast(uint16*, malloc(n * 2))
	int32* i32 = cast(int32*, malloc(n * 4))
	uint32* u32 = cast(uint32*, malloc(n * 4))
	int* w = cast(int*, malloc(n * __word_size__))
	int i = 0
	while (i < n):
		i8[i] = i - 100          # -100 .. n-101
		u8[i] = 200 + i          # 200 .. 200+n-1 (n <= 55)
		i16[i] = i - 20000
		u16[i] = 60000 + i
		i32[i] = i - 2000000000
		u32[i] = 2147483647 - i
		w[i] = i * 1000
		i = i + 1
	int total = 0
	i = 0
	while (i < n):
		total = total + i8[i]
		total = total + u8[i]
		total = total + i16[i]
		total = total + u16[i]
		total = total + i32[i]
		total = total + u32[i]
		total = total + w[i]
		i = i + 1
	# constant indices on register bases (disp = c * size)
	total = total + i8[1] + u8[2] + i16[3] + u16[4] + i32[5] + u32[6] + w[7]
	return total


void test_widths():
	# n = 10: per element i the row sums to
	#  (i-100) + (200+i) + (i-20000) + (60000+i) + (i-2000000000) + (2147483647-i) + 1000i
	#  = 147523747 + 1004 i ; sum over i<10 = 1475237470 + 1004*45 = 1475282650
	#  constants: -99 + 202 + (-19997) + 60004 + (-1999999995) + 2147483641 + 7000 = 147530756
	# (every value fits the 32-bit word, so both widths compute the same)
	assert_equal(1475282650 + 147530756, widths_sum(10))


# --- scales: 1, 2, 4, 8 in the SIB byte, 16 and 32 by a shift, 24 by imul -
int scale_sum(int n):
	pair* p2 = cast(pair*, malloc(n * sizeof(pair)))
	triple* p3 = cast(triple*, malloc(n * sizeof(triple)))
	box* p4 = cast(box*, malloc(n * sizeof(box)))
	int i = 0
	while (i < n):
		p2[i].a = i
		p2[i].b = i * 2
		p3[i].a = i
		p3[i].b = i * 3
		p3[i].c = i * 5
		p4[i].inner.a = i * 7
		p4[i].inner.b = i * 11
		p4[i].tag = i * 13
		i = i + 1
	int total = 0
	i = 0
	while (i < n):
		total = total + p2[i].a + p2[i].b + p3[i].a + p3[i].b + p3[i].c
		total = total + p4[i].inner.a + p4[i].inner.b + p4[i].tag
		total = total + p2[i - 0].b + p3[i + 0].c
		i = i + 1
	# constant indices
	total = total + p2[1].b + p3[2].c + p4[3].tag
	return total


void test_scales():
	# per i: (1+2+1+3+5+7+11+13) i = 43 i, plus 2i + 5i = 7i -> 50 i; sum i<8 = 28*50 = 1400
	# constants: 2 + 10 + 39 = 51
	assert_equal(1451, scale_sum(8))


# --- 'R +/- c' indices, negative and disp32 displacements ---------------
int offset_indices(int* a, int n):
	# a has 2*n + 64 words, filled with their index
	int* mid = a + 32 * __word_size__
	int total = 0
	int i = 32
	while (i < n + 32):
		total = total + a[i - 32]      # i-32
		total = total + a[i + 2]       # i+2
		total = total + mid[i - 32]    # (i-32)+32 = i
		total = total + mid[i - 16]    # i+16
		i = i + 1
	return total


int big_displacement(char* s, int n):
	# s has 70000 bytes, s[k] = k & 127
	int total = 0
	int i = 0
	while (i < n):
		total = total + s[65536 + i] + s[i + 65540] + s[70000 - 1 - i]
		i = i + 1
	return total


void test_offsets():
	int* a = cast(int*, malloc(200 * __word_size__))
	for i in range(200): a[i] = i
	# n = 10, i = 32..41: (i-32) + (i+2) + i + (i+16) = 4i - 14; sum = 4*365 - 140 = 1320
	assert_equal(1320, offset_indices(a, 10))
	char* s = cast(char*, malloc(70000))
	for i in range(70000): s[i] = i & 127
	# 65536 & 127 = 0, 65540 & 127 = 4, 69999 & 127 = 69999 - 546*128 = 111
	# n = 4: sum (0+1+2+3) + (4+5+6+7) + (111+110+109+108) = 6 + 22 + 438 = 466
	assert_equal(466, big_displacement(s, 4))


# --- computed indices (the accumulator as the SIB index) ----------------
int computed_index(int* a, int n):
	int total = 0
	int i = 0
	while (i < n):
		total = total + a[(i * 3) % 7]
		total = total + a[i * 2 + 1]
		a[i * 2] = a[i * 2] + 1
		i = i + 1
	return total


void test_computed():
	int* a = cast(int*, malloc(64 * __word_size__))
	for i in range(64): a[i] = i * 10
	# n = 5: (i*3)%7 = 0,3,6,2,5 -> 0+30+60+21+50 = 161 (a[2] was incremented at i = 1) ; 2i+1 = 1,3,5,7,9 -> 10+30+50+70+90 = 250
	assert_equal(411, computed_index(a, 5))
	# a[0], a[2], a[4], a[6], a[8] incremented
	assert_equal(1, a[0])
	assert_equal(81, a[8])
	assert_equal(10, a[1])


# --- bases on the stack: loop-free functions promote nothing ------------
int stack_base_reads(int* a, int k):
	int local_k = k + 1
	return a[2] + a[k] + a[local_k] + a[k * 2]


int stack_base_writes(int* a, int k):
	a[3] = 30
	a[k] = 40
	int j = k + 2
	a[j] = 50
	a[k * 2] = 60
	return a[3] + a[k] + a[j] + a[k * 2]


int stack_base_in_loop(int** pa, int n):
	# the base is read through a pointer so it never promotes; the
	# index does
	int total = 0
	int i = 0
	while (i < n):
		int* a = *pa
		total = total + a[i] + a[i + 1]
		a[i] = a[i] + 1
		i = i + 1
	return total


void test_stack_bases():
	int* a = cast(int*, malloc(32 * __word_size__))
	for i in range(32): a[i] = i
	assert_equal(2 + 5 + 6 + 10, stack_base_reads(a, 5))
	assert_equal(30 + 40 + 50 + 60, stack_base_writes(a, 4))
	for i in range(32): a[i] = i
	int* keep = a
	# n = 6: a[i] + a[i+1] = 2i + 1 -> sum i<6 = 30 + 6 = 36
	assert_equal(36, stack_base_in_loop(&keep, 6))
	assert_equal(6, a[5])
	assert_equal(6, a[6])


# --- fields through promoted and stack-resident pointers ----------------
int field_walk(cursor* c, int n):
	int total = 0
	int i = 0
	while (i < n):
		c.status = c.status + 1
		c.bit_pos += 3
		c.count++
		total = total + c.data[c.bit_pos] + c.status
		i = i + 1
	return total


int field_plain(cursor* c):
	c.status = 7
	c.bit_pos = c.status * 2
	int v = c.data[c.bit_pos]
	c.count = v + c.bit_pos
	return c.count


void test_fields():
	cursor c
	c.status = 0
	c.bit_pos = 0
	c.count = 0
	char* d = cast(char*, malloc(64))
	for i in range(64): d[i] = i
	c.data = d
	# n = 4: bit_pos 3,6,9,12 ; status 1,2,3,4 -> (3+1)+(6+2)+(9+3)+(12+4) = 40
	assert_equal(40, field_walk(&c, 4))
	assert_equal(4, c.count)
	assert_equal(12, c.bit_pos)
	assert_equal(14 + 14, field_plain(&c))


# --- chains: p.a[i], a[i].f, a[i].inner.b, &a[i], &p.f -------------------
int chain_sum(cursor* c, box* bs, int n):
	int total = 0
	int i = 0
	while (i < n):
		total = total + c.data[i] + bs[i].tag + bs[i].inner.b
		bs[i].inner.a = i
		bs[i].tag += 2
		i = i + 1
	return total


int address_sum(int* a, box* bs, int n):
	int total = 0
	int i = 0
	while (i < n):
		int* pa = &a[i]
		int* pb = &bs[i].inner.b
		*pa = *pa + 1
		total = total + *pa + *pb
		i = i + 1
	return total


void test_chains():
	cursor c
	char* d = cast(char*, malloc(16))
	for i in range(16): d[i] = i + 1
	c.data = d
	box* bs = cast(box*, malloc(8 * sizeof(box)))
	for i in range(8):
		bs[i].inner.a = 0
		bs[i].inner.b = i * 10
		bs[i].tag = i
	# n = 5: (i+1) + i + 10i = 12i + 1 -> 120 + 5 = 125
	assert_equal(125, chain_sum(&c, bs, 5))
	assert_equal(4, bs[4].inner.a)
	assert_equal(6, bs[4].tag)
	int* a = cast(int*, malloc(8 * __word_size__))
	for i in range(8): a[i] = i
	# n = 5: (i+1) + 10i = 11i + 1 -> 110 + 5 = 115
	assert_equal(115, address_sum(a, bs, 5))
	assert_equal(5, a[4])


# --- stores: constants, registers, locals, expressions, every width -----
int store_shapes(widths* ws, int n):
	int reg = 5
	int* arr = cast(int*, malloc(n * __word_size__))
	int** keep = &arr
	int i = 0
	while (i < n):
		int* a = *keep
		a[i] = 7                     # constant
		a[i] = a[i] + reg            # expression
		a[i * 2 % n] = reg           # computed index, register value
		ws[i].i8 = -3
		ws[i].u8 = 250
		ws[i].i16 = -1000
		ws[i].u16 = 65000
		ws[i].i32 = -70000
		ws[i].u32 = 100000
		ws[i].w = i
		ws[i].f32 = 1.5
		ws[i].p = a
		ws[i].w = ws[i].w + ws[i].i8 + ws[i].u8
		reg = reg + 1
		i = i + 1
	int total = 0
	i = 0
	while (i < n):
		total = total + arr[i] + ws[i].i8 + ws[i].u8 + ws[i].i16 + ws[i].u16 + ws[i].i32 + ws[i].u32 + ws[i].w
		total = total + cast(int, ws[i].f32) + ws[i].p[0]
		i = i + 1
	return total


void test_stores():
	widths* ws = cast(widths*, malloc(8 * sizeof(widths)))
	# n = 4: arr: a[i] = 7 + (5+i) = 12+i, then a[(2i)%4] = 5+i: i=0 -> a[0]=5,
	# i=1 -> a[2]=6, i=2 -> a[0]=7, i=3 -> a[2]=8 ; final arr = 7, 13, 8, 15 (sum 43)
	# ws[i].w = i - 3 + 250 = 247 + i
	# per element: -3 + 250 - 1000 + 65000 - 70000 + 100000 + (247 + i) + 1 + 7(=a[0]) = 94502 + i
	# x4 = 378008 + 6 = 378014
	assert_equal(43 + 378014, store_shapes(ws, 4))


# --- compound stores and increments on elements, fields and locals ------
int compound_elements(int* a, pair* ps, int n):
	int x = 3
	int* px = &x          # x stays on the stack
	int i = 0
	while (i < n):
		a[i] += i
		a[i] -= 1
		a[i] *= 2
		a[i] |= 1
		a[i] &= 1023
		a[i] ^= 2
		a[i] <<= 1
		a[i] >>= 1
		a[i]++
		a[i]--
		++a[i]
		ps[i].a += 10
		ps[i].b -= 10
		ps[i].a++
		--ps[i].b
		*px += 2
		*px = *px * 1
		x += 1
		x = x + 1
		i = i + 1
	return x


void test_compound():
	int* a = cast(int*, malloc(8 * __word_size__))
	pair* ps = cast(pair*, malloc(8 * sizeof(pair)))
	for i in range(8):
		a[i] = i * 10
		ps[i].a = i
		ps[i].b = i
	# x: 3 + 4 per iteration, n = 3 -> 15
	assert_equal(15, compound_elements(a, ps, 3))
	# a[i] = (((((10i + i - 1) * 2) | 1) & 1023) ^ 2), then << 1 >> 1, +1 -1 +1
	# i=0: (-1*2)|1 = -1 ; & 1023 = 1023 ; ^2 = 1021 ; +1 = 1022
	# i=1: (10*2)|1 = 21 ; 21 ^ 2 = 23 ; +1 = 24
	# i=2: (21*2)|1 = 43 ; 43 ^ 2 = 41 ; +1 = 42
	assert_equal(1022, a[0])
	assert_equal(24, a[1])
	assert_equal(42, a[2])
	assert_equal(30, a[3])
	assert_equal(11, ps[0].a)
	assert_equal(-11, ps[0].b)
	assert_equal(13, ps[2].a)
	assert_equal(-9, ps[2].b)


# --- the left side is evaluated first: a store whose right side writes
# the base or the index -------------------------------------------------
int store_order(int* a, int* b, int n):
	int i = 0
	int* p = b
	while (i < n):
		a[i] = (i = i + 1)        # a[old i] = new i
		p[0] = cast(int, (p = p + __word_size__))    # old p[0] = new p
	return i


void test_store_order():
	int* a = cast(int*, malloc(8 * __word_size__))
	int* b = cast(int*, malloc(8 * __word_size__))
	for i in range(8):
		a[i] = -1
		b[i] = -1
	assert_equal(1, store_order(a, b, 1))
	assert_equal(1, a[0])
	assert_equal(-1, a[1])
	assert_equal(cast(int, &b[1]), b[0])
	assert_equal(-1, b[1])
	assert_equal(4, store_order(a, b, 4))
	# a[0..3] = 1..4 ; b[k] = &b[k+1] for k < 4
	assert_equal(1, a[0])
	assert_equal(4, a[3])
	assert_equal(-1, a[4])
	assert_equal(cast(int, &b[4]), b[3])
	assert_equal(-1, b[4])


# --- byte compares against constants ---------------------------------------
int count_bytes(char* s, uint8* u, int8* sg, int n):
	int zeros = 0
	int lows = 0
	int highs = 0
	int negs = 0
	int i = 0
	while (i < n):
		if (s[i] == 0): zeros = zeros + 1
		if (s[i] != 'a'): lows = lows + 1
		if (u[i] >= 200): highs = highs + 1
		if (u[i] < 3): lows = lows + 1
		if (sg[i] == -1): negs = negs + 1
		if (sg[i] < -100): negs = negs + 1
		i = i + 1
	return zeros + lows * 10 + highs * 100 + negs * 1000


void test_byte_compares():
	char* s = cast(char*, malloc(16))
	uint8* u = cast(uint8*, malloc(16))
	int8* sg = cast(int8*, malloc(16))
	for i in range(16):
		s[i] = 0
		if (i % 3 == 0): s[i] = 'a'
		u[i] = i * 20              # 0,20,..,300 wraps: i=13 -> 260-256 = 4, 14 -> 24, 15 -> 44
		sg[i] = -1
		if (i % 2 == 0): sg[i] = -120
	# n = 16: zeros: i not multiple of 3 -> 10 ; lows: s != 'a' -> 10, u < 3 -> i=0 -> 1 : 11
	# highs: u >= 200 -> i = 10, 11, 12 (200, 220, 240) -> 3
	# negs: sg == -1 -> odd i -> 8 ; sg < -100 -> even i -> 8 : 16
	assert_equal(10 + 110 + 300 + 16000, count_bytes(s, u, sg, 16))


# --- nested subscripts, pointer to pointer, struct element copies --------
int nested(int** rows, int n):
	int total = 0
	int i = 0
	while (i < n):
		int j = 0
		while (j < n):
			total = total + rows[i][j]
			rows[j][i] = rows[i][j] + 1
			j = j + 1
		i = i + 1
	return total


int struct_copies(pair* ps, int n):
	int total = 0
	int i = 0
	while (i < n):
		pair q = ps[i]
		q.a = q.a + 100
		ps[i] = q
		total = total + ps[i].a + q.b
		i = i + 1
	return total


void test_nested():
	int** rows = cast(int**, malloc(4 * __word_size__))
	for i in range(4):
		rows[i] = cast(int*, malloc(4 * __word_size__))
		for j in range(4): rows[i][j] = i * 4 + j
	# sum of 0..15 after the in-place updates: rows[j][i] = rows[i][j] + 1
	# reads happen before each write; walk it: i=0: j=0: +0, r00=1; j=1: +1, r10=2; j=2: +2, r20=3; j=3: +3, r30=4
	# i=1: j=0: +r10=2, r01=3; j=1: +5, r11=6; j=2: +6, r21=7; j=3: +7, r31=8
	# i=2: j=0: +r20=3, r02=4; j=1: +r21=7, r12=8; j=2: +10, r22=11; j=3: +11, r32=12
	# i=3: j=0: +r30=4, r03=5; j=1: +r31=8, r13=9; j=2: +r32=12, r23=13; j=3: +15, r33=16
	# total = 6 + 20 + 31 + 39 = 96
	assert_equal(96, nested(rows, 4))
	pair* ps = cast(pair*, malloc(4 * sizeof(pair)))
	for i in range(4):
		ps[i].a = i
		ps[i].b = i * 2
	# (100 + i) + 2i = 100 + 3i -> 300 + 9 = 309
	assert_equal(309, struct_copies(ps, 3))
	assert_equal(102, ps[2].a)


# --- stack locals: x = v, x = R, x = 5, x += 1, struct-returning right side -
pair make_pair(int a, int b):
	pair p
	p.a = a
	p.b = b
	return p


int stack_locals(int n):
	int x = 0
	int y = 0
	int z = 0
	int* keep_x = &x
	int* keep_y = &y
	int* keep_z = &z
	int i = 0
	while (i < n):
		x = 5
		x += i
		y = x
		z = make_pair(i, x).b + make_pair(y, 1).a
		y = i
		i = i + 1
	return x + y * 10 + z * 100 + *keep_x + *keep_y + *keep_z
# z = x + y = (5+i) + (5+i) = 10 + 2i ; at i = n-1: x = 5 + n - 1, y = n - 1


void test_stack_locals():
	# n = 4: x = 8, y = 3, z = 16 -> 8 + 30 + 1600 + 8 + 3 + 16 = 1665
	assert_equal(1665, stack_locals(4))


# --- compares against constants at every width, folded constants ---------
int compare_widths(widths* ws, int n):
	int acc = 0
	int i = 0
	while (i < n):
		if (ws[i].i8 == -1): acc = acc + 1
		if (ws[i].i8 < -100): acc = acc + 2
		if (ws[i].u8 >= 200): acc = acc + 4
		if (ws[i].u8 != 24): acc = acc + 8
		if (ws[i].i16 <= -300): acc = acc + 16
		if (ws[i].i16 == 1000): acc = acc + 32
		if (ws[i].u16 > 40000): acc = acc + 64
		if (ws[i].u16 != 0): acc = acc + 128
		if (ws[i].i32 < 0): acc = acc + 256
		if (ws[i].i32 == 100000): acc = acc + 512
		if (ws[i].u32 == 7): acc = acc + 1024
		if (ws[i].u32 >= 2000000000): acc = acc + 2048
		if (ws[i].w != -5): acc = acc + 4096
		if (ws[i].w > 1000000): acc = acc + 8192
		i = i + 1
	return acc


int constants(int n):
	int a = 0
	int b = 0
	int i = 0
	while (i < n):
		a = -3
		b = -(-7)
		a = a + i
		b = b - (-1)
		int m = -(0x7fffffff)
		if (m < 0): b = b + 1000
		if (0 - m > 0): b = b + 2000
		i = i + 1
	return a * 10000 + b


void test_compares():
	widths* ws = cast(widths*, malloc(3 * sizeof(widths)))
	ws[0].i8 = -1
	ws[0].u8 = 200
	ws[0].i16 = -300
	ws[0].u16 = 40001
	ws[0].i32 = -7
	ws[0].u32 = 7
	ws[0].w = -5
	ws[1].i8 = -120
	ws[1].u8 = 24
	ws[1].i16 = 1000
	ws[1].u16 = 0
	ws[1].i32 = 100000
	ws[1].u32 = 2000000000
	ws[1].w = 2000000
	ws[2].i8 = 5
	ws[2].u8 = 255
	ws[2].i16 = 5
	ws[2].u16 = 65535
	ws[2].i32 = 0
	ws[2].u32 = 0
	ws[2].w = 0
	# ws[0]: 1 + 4 + 8 + 16 + 64 + 128 + 256 + 1024 = 1501
	# ws[1]: 2 + 32 + 512 + 2048 + 4096 + 8192 = 14882
	# ws[2]: 4 + 8 + 64 + 128 + 4096 = 4300
	assert_equal(1501 + 14882 + 4300, compare_widths(ws, 3))
	# n = 4: a = -3 + 3 = 0, b = 7 + 1 + 1000 + 2000 = 3008
	assert_equal(3008, constants(4))


int main():
	test_widths()
	test_scales()
	test_offsets()
	test_computed()
	test_stack_bases()
	test_fields()
	test_chains()
	test_stores()
	test_compound()
	test_store_order()
	test_byte_compares()
	test_nested()
	test_stack_locals()
	test_compares()
	println(c"addressing_mode_test passed")
	return 0
