# Integer-only freestanding workload for tests/kernel_codegen_test.w,
# compiled with --emit=obj --freestanding --kernel-codegen. It exercises
# the code shapes a kernel translation unit produces: register-promoted
# locals, deep expressions, recursion, struct copies, fixed arrays,
# narrow loads and stores, function pointers, switch, many-argument
# calls, calls out to C and back, string literals and global pointer
# tables. kc_main returns a checksum the test compares between a plain
# run and a run whose memory below %rsp is clobbered before every
# instruction (an interrupt arriving at any point).
type kc_binary = fn(int, int) -> int

extern int kc_c_mix(int a, int b, int c, int d, int e, int f, int g, int h)
extern int kc_c_unwind()

struct kc_point:
	int x
	int y
	int8 tag
	int16 weight

struct kc_box:
	kc_point lo
	kc_point hi
	int[4] extra

int[16] kc_table
int kc_counter = 3
char* kc_text = c"kernel codegen corpus"
int* kc_counter_cell = &kc_counter


int kc_add(int a, int b):
	return a + b


int kc_xor(int a, int b):
	return (a ^ b) + 1


kc_binary* kc_ops_add = kc_add
kc_binary* kc_ops_xor = kc_xor


int kc_fib(int n):
	if (n < 2): return n
	return kc_fib(n - 1) + kc_fib(n - 2)


int kc_many(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j):
	return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10


int kc_point_sum(kc_point p):
	return p.x + p.y + p.tag + p.weight


kc_point kc_point_make(int x, int y):
	kc_point p
	p.x = x
	p.y = y
	p.tag = cast(int8, x - y)
	p.weight = cast(int16, x * y)
	return p


int kc_box_area(kc_box* b):
	return (b.hi.x - b.lo.x) * (b.hi.y - b.lo.y) + b.extra[1] + b.extra[3]


int kc_structs():
	kc_box b
	b.lo = kc_point_make(1, 2)
	b.hi = kc_point_make(9, 14)
	for i in range(4): b.extra[i] = i * 11
	kc_box c = b
	c.hi.x = c.hi.x + 5
	kc_point q = c.lo
	return kc_box_area(&b) + kc_box_area(&c) + kc_point_sum(q) + kc_point_sum(c.hi)


int kc_switch(int v):
	int r = 0
	switch (v & 7):
		case 0: r = 17
		case 1, 2: r = v * 3
		case 3: r = v << 2
		case 5: r = v / 3
		default: r = v % 5
	return r


int kc_bytes():
	char[64] buf
	for i in range(64): buf[i] = cast(char, i * 7)
	int16[8] halves
	for i in range(8): halves[i] = cast(int16, -i * 1000)
	int total = 0
	for i in range(64): total = total + (buf[i] & 255)
	for i in range(8): total = total + halves[i]
	int n = 0
	while (kc_text[n] != 0): n = n + 1
	return total + n


# Enough simultaneously live locals and loops to make register promotion,
# parked expression registers and call spills all appear.
int kc_promoted(int seed):
	int a = seed
	int b = seed * 3 + 1
	int c = seed ^ 0x55
	int d = 0
	int e = 1
	for i in range(40):
		a = a + i
		b = b ^ (a << 1)
		c = (c + b) & 0xffff
		d = d + kc_add(a & 15, c & 15)
		e = (e * 3 + d) % 100003
	int[16] mix
	for i in range(16):
		mix[i] = a * i + b - c
		kc_table[i] = mix[i] & 1023
	int s = 0
	for i in range(16): s = s + mix[i] % 7 + kc_table[15 - i]
	# the C side walks the frame-pointer chain through every W frame
	return a + b + c + d + e + s + kc_c_unwind()


int kc_pointers():
	int total = 0
	kc_binary* op = kc_ops_add
	total = total + op(20, 22)
	op = kc_ops_xor
	total = total + op(6, 3)
	*kc_counter_cell = *kc_counter_cell + 4
	total = total + kc_counter
	int[8] cells
	int* p = &cells[0]
	for i in range(8): p[i] = i * i
	int* q = &cells[3]
	return total + *q + p[7]


int kc_shifts(int x):
	int r = 0
	for i in range(12):
		r = r + ((x >> i) & 1) * (1 << i)
		r = r ^ ((x << (i & 7)) >> 3)
	int y = -x
	return r + (y >> 2) + (y / 7) + (y % 9) + (x * x) / 13


export int kc_main():
	int sum = kc_fib(15)
	sum = sum + kc_many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
	sum = sum + kc_structs()
	for v in range(16): sum = sum + kc_switch(v * 5 + 1)
	sum = sum + kc_bytes()
	sum = sum + kc_promoted(7)
	sum = sum + kc_pointers()
	sum = sum + kc_shifts(12345)
	sum = sum + kc_c_mix(1, 2, 3, 4, 5, 6, 7, sum & 255)
	return sum


# Called by the C side from inside kc_c_mix: a C -> W -> C -> W chain.
export int kc_callback(int a, int b):
	return kc_fib(a) * b + kc_promoted(a)
