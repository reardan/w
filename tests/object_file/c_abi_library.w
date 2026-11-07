# Freestanding W library built with --c-abi (tests/object_file_test.w
# compiles it with --emit=obj --freestanding --c-abi and links it with
# tests/object_file/c_abi_main.c). Every function of this root file
# except the 'static' ones is a global System V symbol; function
# pointers are System V pointers in both directions, so C calls W
# through tables and W calls C callbacks through pointers.
type binop = fn(int, int) -> int
type sum8 = fn(int, int, int, int, int, int, int, int) -> int
type narrow_result = fn(int) -> int32
type narrow_byte = fn(int) -> uint8
type mix = fn(float64, float32, int) -> float64

struct w_ops:
	binop* add
	binop* mul
	sum8* sum

# Records with float members travel in SSE eightbytes.
struct fpair:
	float64 x
	float64 y

struct mixed:
	float64 f
	int i

struct imixed:
	int i
	float32 f
	float32 g

type mixed_maker = fn(float64, int) -> mixed

extern int c_sub(int a, int b)
extern float64 c_float_records(fpair p, mixed m, imixed q)
extern int c_weigh8(int a, int b, int c, int d, int e, int f, int g, int h)

int w_calls = 0
static int w_private_total = 0


int w_add(int a, int b):
	w_calls = w_calls + 1
	return a + b


int w_mul(int a, int b):
	return a * b


static int w_hidden(int a, int b):
	w_private_total = w_private_total + a - b
	return a - b


# Every argument weighted by its position, so a misplaced one shows.
int w_weigh8(int a, int b, int c, int d, int e, int f, int g, int h):
	return a + 10 * b + 100 * c + 1000 * d + 10000 * e + 100000 * f + 1000000 * g + 10000000 * h


int w_narrow(int32 a, uint8 b, int16 c, uint32 d):
	int sum = a
	sum = sum + b
	sum = sum + c
	sum = sum + d
	return sum


float64 w_mix(float64 x, float32 y, int k):
	float64 wide = y
	return x * wide + k


float32 w_half(float32 x):
	return x * cast(float32, 0.5)


void w_store(int* out, int value):
	*out = value


# A static table of System V function pointers: W functions (one of
# them file-local) and C functions, defined before or after the table.
int w_late(int a, int b);
binop* w_table_add = w_add
binop* w_table_hidden = w_hidden
binop* w_table_c_sub = c_sub
binop* w_table_late = w_late
sum8* w_table_weigh8 = w_weigh8


int w_late(int a, int b):
	return a * 100 + b


# W calls C (and W) through pointers it is given.
int w_call_binop(binop* f, int a, int b):
	return f(a, b)


int w_call_sum8(sum8* f):
	return f(1, 2, 3, 4, 5, 6, 7, 8)


int w_call_narrow(narrow_result* f, int x):
	return f(x)


int w_call_byte(narrow_byte* f, int x):
	return f(x)


float64 w_call_mix(mix* f):
	return f(1.5, cast(float32, 2.0), 3)


# The C functions' own addresses, taken in W at run time.
int w_c_through_locals(int a, int b):
	binop* sub = c_sub
	sum8* weigh = &c_weigh8
	return sub(a, b) + weigh(1, 0, 0, 0, 0, 0, 0, 1)


# A W function's address handed to C, called back by C.
binop* w_pick(int which):
	if (which == 0): return w_add
	if (which == 1): return &w_mul
	if (which == 2): return w_hidden
	return c_sub


# W calls W through a pointer, and through a C-filled struct of pointers.
int w_self_indirect(int a):
	binop* f = w_mul
	return f(a, a)


int w_ops_run(w_ops* ops):
	binop* add = ops.add
	binop* mul = ops.mul
	sum8* sum = ops.sum
	return add(1, 2) + mul(3, 4) + sum(1, 1, 1, 1, 1, 1, 1, 1)


void w_ops_fill(w_ops* ops):
	ops.add = w_add
	ops.mul = c_sub
	ops.sum = w_weigh8


int w_private_total_value():
	return w_private_total


fpair w_make_fpair(float64 x, float64 y):
	fpair p
	p.x = x
	p.y = y
	return p


mixed w_make_mixed(float64 f, int i):
	mixed m
	m.f = f
	m.i = i
	return m


imixed w_make_imixed(int i, float32 f):
	imixed q
	q.i = i
	q.f = f
	q.g = f + f
	return q


# W hands C's float records back to C, and calls C's maker.
float64 w_float_records(fpair p, mixed m, imixed q):
	return c_float_records(p, m, q)


float64 w_call_float_records(mixed_maker* make):
	mixed m = make(2.5, 9)
	return m.f * cast(float64, 2) + m.i
