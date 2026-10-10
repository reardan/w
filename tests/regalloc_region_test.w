# wbuild: x64
# The function region and the register gain ranking (unit O2,
# compiler/regalloc_scan.w's rs_fn_rank, regalloc_fn_region_enter and
# rs_assign_registers' third round): on x64 a body the scan sees whole
# with no visible call keeps its best arguments and locals in the
# caller-saved registers the loops use, for the whole body, and a
# loop-free body with calls gives a name with enough register gain a
# callee-saved register. A local declared inside a loop body takes a
# register of the loop's own (class 'B') on x86 and x64. Every case
# asserts computed values only; regalloc_diff_test compares the same
# program built with --no-regs.
import lib.lib
import lib.assert


struct cursor:
	char* data
	int length
	int pos
	int bit
	int status


# A leaf reading its pointer argument's fields over and over (the
# inflate bit reader's shape): the argument lives in a register.
int cursor_bit(cursor* c):
	if (c.status != 0): return 0
	if (c.pos >= c.length):
		c.status = 1
		return 0
	int b = shr(c.data[c.pos] & 255, c.bit) & 1
	c.bit = c.bit + 1
	if (c.bit == 8):
		c.bit = 0
		c.pos = c.pos + 1
	return b


cursor* cursor_new(char* data, int length):
	cursor* c = cast(cursor*, malloc(sizeof(cursor)))
	c.data = data
	c.length = length
	c.pos = 0
	c.bit = 0
	c.status = 0
	return c


void test_leaf_fields():
	char* data = c"\x05\xa0"
	cursor* c = cursor_new(data, 2)
	int v = 0
	int i = 0
	while (i < 16):
		v = v | (cursor_bit(c) << i)
		i = i + 1
	assert_equal(0xa005, v)
	assert_equal(0, c.status)
	assert_equal(0, cursor_bit(c))
	assert_equal(1, c.status)


# Locals declared at the top level, in a nested block and inside a loop
# body, compound assignment, compares and '++'-style updates.
int leaf_mix(int* a, int n, int k):
	int total = 0
	int hits = 0
	int i = 0
	while (i < n):
		int x = a[i]
		int y = x * k
		if (y > 10):
			int z = y - 10
			total += z
			hits = hits + 1
		else:
			total -= x
		i = i + 1
	if (hits > 2): total = total * 2
	return total + hits


void test_leaf_mix():
	int* a = cast(int*, malloc(8 * __word_size__))
	for j in range(8): a[j] = j
	# k = 3: y = 0 3 6 9 12 15 18 21 -> z for j >= 4: 2+5+8+11 = 26,
	# minus 0+1+2+3 = 6 -> 20, hits 4 -> 40 + 4
	assert_equal(44, leaf_mix(a, 8, 3))
	assert_equal(-28, leaf_mix(a, 8, 1))
	free(cast(char*, a))


# A range loop's variable and a loop-free leaf with only arguments.
int leaf_range(int lo, int hi, int step):
	int s = 0
	for v in range(lo, hi, step):
		s += v
		if (s > 1000): s = s - 1000
	return s


int leaf_args(int a, int b, int c):
	if (a < b):
		if (b < c): return 1
		if (a < c): return 2
		return 3
	if (a < c): return 4
	if (b < c): return 5
	return 6


void test_leaf_range():
	assert_equal(45, leaf_range(0, 10, 1))
	assert_equal(20, leaf_range(0, 10, 2))
	assert_equal(1, leaf_args(1, 2, 3))
	assert_equal(2, leaf_args(1, 3, 2))
	assert_equal(3, leaf_args(2, 3, 1))
	assert_equal(4, leaf_args(2, 1, 3))
	assert_equal(5, leaf_args(3, 1, 2))
	assert_equal(6, leaf_args(3, 2, 1))


# Hidden calls the scan cannot see (a container subscript, an indexed
# container field): the region's registers survive them through their
# homes.
struct holder:
	list[int] items
	int bias


int leaf_hidden(holder* h, list[int] extra, int n):
	int s = 0
	int i = 0
	while (i < n):
		s = s + h.items[i] + extra[i] + h.bias
		i = i + 1
	h.bias = h.bias + 1
	return s + h.bias


void test_hidden_calls():
	holder* h = cast(holder*, malloc(sizeof(holder)))
	h.items = new list[int]
	h.bias = 100
	list[int] extra = new list[int]
	for j in range(5):
		h.items.push(j)
		extra.push(j * 10)
	# sum of j + 10j + 100 over 0..4 = 10 + 100 + 500, then bias 101
	assert_equal(711, leaf_hidden(h, extra, 5))
	assert_equal(101, h.bias)


# Narrow locals and arguments in the region: wrap-around matches the
# stack word.
uint32 leaf_narrow(uint32 x, int32 y, int n):
	uint32 acc = x
	int32 neg = y
	int i = 0
	while (i < n):
		acc = acc * 31 + 7
		acc = acc ^ (acc >> 3)
		neg = neg - 1000000000
		i = i + 1
	if (neg < 0): acc = acc + 1
	return acc


uint32 narrow_reference(uint32 x, int32 y, int n):
	uint32* acc = cast(uint32*, malloc(8))
	acc[0] = x
	int32 neg = y
	for i in range(n):
		acc[0] = acc[0] * 31 + 7
		acc[0] = acc[0] ^ (acc[0] >> 3)
		neg = neg - 1000000000
	if (neg < 0): acc[0] = acc[0] + 1
	uint32 r = acc[0]
	free(cast(char*, acc))
	return r


void test_narrow():
	assert_equal(cast(int, narrow_reference(0xdeadbee, 5, 9)), cast(int, leaf_narrow(0xdeadbee, 5, 9)))
	assert_equal(cast(int, narrow_reference(1, -5, 3)), cast(int, leaf_narrow(1, -5, 3)))


# Multiple assignment and swaps of region names.
int leaf_swap(int a, int b, int n):
	int x = a
	int y = b
	int i = 0
	while (i < n):
		x, y = y, x + y
		i = i + 1
	return x


void test_swap():
	assert_equal(55, leaf_swap(0, 1, 10))
	assert_equal(1, leaf_swap(0, 1, 1))


# An address-taken local stays on the stack; its neighbours may not.
int leaf_address(int a, int b):
	int t = a
	int u = b
	int* p = &t
	p[0] = p[0] + u
	u = u + 1
	if (u > t): return u - t
	return t - u


void test_address():
	assert_equal(2, leaf_address(3, 4))
	assert_equal(9, leaf_address(10, 1))


# A loop-free body with calls: a pointer argument read through many
# fields takes a callee-saved register (rs_assign_registers' third round).
int note(int v):
	return v + 1


int fields_with_calls(cursor* c):
	int a = note(c.pos) + c.length + c.bit + c.status
	c.pos = c.pos + note(c.bit)
	c.bit = c.length - c.pos
	return a + c.pos + c.bit + c.status


void test_fields_with_calls():
	cursor* c = cursor_new(c"abc", 3)
	c.pos = 1
	c.bit = 2
	# a = 2 + 3 + 2 + 0 = 7; pos = 1 + 3 = 4; bit = 3 - 4 = -1
	assert_equal(10, fields_with_calls(c))
	assert_equal(4, c.pos)
	assert_equal(-1, c.bit)


# Locals declared inside a loop body with more names live than the
# function's callee-saved registers: the loop's own registers (class
# 'B'), redeclared every iteration.
int loop_temps(int n):
	int a = 1
	int b = 2
	int c = 3
	int d = 4
	int e = 5
	int g = 6
	int i = 0
	while (i < n):
		a = a + 1
		b = b + a
		c = c + b
		d = d + c
		e = e + d
		g = g + e
		int t1 = a + b
		int t2 = t1 * 3
		t2 = t2 - c
		int t3 = t2 + t1
		a = a + (t3 & 7)
		i = i + 1
	return a + b + c + d + e + g


int loop_temps_reference(int n):
	int* v = cast(int*, malloc(8 * __word_size__))
	for j in range(6): v[j] = j + 1
	for i in range(n):
		v[0] = v[0] + 1
		v[1] = v[1] + v[0]
		v[2] = v[2] + v[1]
		v[3] = v[3] + v[2]
		v[4] = v[4] + v[3]
		v[5] = v[5] + v[4]
		v[6] = v[0] + v[1]
		v[7] = v[6] * 3 - v[2]
		v[0] = v[0] + ((v[7] + v[6]) & 7)
	int r = v[0] + v[1] + v[2] + v[3] + v[4] + v[5]
	free(cast(char*, v))
	return r


void test_loop_temps():
	assert_equal(loop_temps_reference(10), loop_temps(10))
	assert_equal(loop_temps_reference(1), loop_temps(1))
	assert_equal(21, loop_temps(0))


int main():
	test_leaf_fields()
	test_leaf_mix()
	test_leaf_range()
	test_hidden_calls()
	test_narrow()
	test_swap()
	test_address()
	test_fields_with_calls()
	test_loop_temps()
	println(c"regalloc_region_test passed")
	return 0
