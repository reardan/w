# Freestanding W library for --c-abi records, C-variadic definitions,
# wide signatures and unsized extern arrays (tests/object_c_abi_test.w
# links it with tests/object_file/c_abi_records_main.c): structs and
# unions by value in both directions, in registers and in memory,
# directly and through function pointers.
import lib.c_va

struct pair:
	int a
	int b

struct small:
	int32 x
	int32 y

struct tiny:
	uint8 c

struct big:
	int a
	int b
	int c
	int d

union word_or_bytes:
	int w
	uint8 b

type pair_maker = fn(int, int) -> pair
type big_maker = fn(int) -> big
type pair_taker = fn(pair, big, int) -> int

extern pair c_make_pair(int a, int b)
extern big c_make_big(int seed)
extern int c_sum_records(pair p, small s, big g, tiny t, int k)
extern int c_vsum(int n, c_va_list* ap)
extern int c_printf_like(int n, ...)
extern int c_tagged_vsum(pair p, int n, ...)
extern int c_vrecord_tail(int n, ...)
extern int32[] c_numbers
extern uint8[] c_bytes


int w_sum_pair(pair p):
	return p.a + p.b


int w_sum_records(pair p, small s, big g, tiny t, int k):
	return p.a + 10 * p.b + 100 * s.x + 1000 * s.y + 10000 * g.a + 100000 * g.d + 1000000 * t.c + 10000000 * k


pair w_make_pair(int a, int b):
	pair p
	p.a = a
	p.b = b
	return p


small w_make_small(int x, int y):
	small s
	s.x = x
	s.y = y
	return s


tiny w_make_tiny(int c):
	tiny t
	t.c = c
	return t


big w_make_big(int seed):
	big g
	g.a = seed
	g.b = seed + 1
	g.c = seed + 2
	g.d = seed + 3
	return g


int w_union_word(word_or_bytes u):
	return u.w


# Records past the six argument registers go to the stack.
int w_late_record(int a, int b, int c, int d, int e, pair p, pair q):
	return a + b + c + d + e + p.a * 10 + p.b * 100 + q.a * 1000 + q.b * 10000


# More than ten parameters, a narrow one past the tenth.
int w_twelve(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j, int k, int8 l):
	return a + b + c + d + e + f + g + h + i + j + k * 1000 + l * 100000


# W calls C with records.
int w_calls_c():
	pair p = c_make_pair(3, 4)
	big g = c_make_big(10)
	small s
	s.x = 5
	s.y = 6
	tiny t
	t.c = 7
	return p.a + p.b * 10 + g.a * 100 + g.d * 1000 + c_sum_records(p, s, g, t, 9) * 10000


# And through C's function pointers.
int w_calls_pointers(pair_maker* make, big_maker* make_big, pair_taker* take):
	pair p = make(1, 2)
	big g = make_big(20)
	return take(p, g, 3) + p.b * 1000000


# C-variadic definitions.
int w_vsum(int n, ... va):
	c_va_list ap
	c_va_start(&ap, va)
	int total = 0
	for i in range(n): total = total + c_va_arg(&ap)
	c_va_end(&ap)
	return total


# Records and copies through a va_list, then handed to C.
int w_vrecords(int n, ... va):
	c_va_list ap
	c_va_start(&ap, va)
	c_va_list copy
	c_va_copy(&copy, &ap)
	pair* p = cast(pair*, c_va_arg_record(&ap, 16))
	big* g = cast(big*, c_va_arg_record(&ap, 32))
	int rest = c_vsum(n, &ap)
	pair* again = cast(pair*, c_va_arg_record(&copy, 16))
	return p.a + p.b * 10 + g.d * 100 + rest * 1000 + again.b * 100000


# W calls its own C-variadic definition and C's.
int w_vcalls():
	return w_vsum(3, 1, 2, 3) + 10 * c_printf_like(2, 5, 6)


# Unsized extern arrays index without a length.
int w_numbers(int i):
	return c_numbers[i]


uint8* w_bytes_at(int i):
	return &c_bytes[i]


# Records by value in a C-variadic call: among the fixed parameters
# (an INTEGER pair in two registers, then the variadic words) and in the
# variadic tail (a register pair, a MEMORY big on the stack, a small).
int w_vrecord_calls():
	pair p
	p.a = 1
	p.b = 2
	big g
	g.a = 3
	g.b = 4
	g.c = 5
	g.d = 6
	small s
	s.x = 7
	s.y = 8
	return c_tagged_vsum(p, 2, 10, 20) + 1000 * c_vrecord_tail(9, p, g, s)
