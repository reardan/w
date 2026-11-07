/* C host for tests/object_file/c_abi_library.w (--c-abi): calls every
   W function by name, through the W object's static pointer table and
   through pointers W returns, and hands W C callbacks. A W int is 64
   bits on x64, so the C side uses long. */
#include <stdio.h>

typedef long (*binop)(long, long);
typedef long (*sum8)(long, long, long, long, long, long, long, long);
struct w_ops {
	binop add;
	binop mul;
	sum8 sum;
};

long w_add(long a, long b);
long w_mul(long a, long b);
long w_weigh8(long a, long b, long c, long d, long e, long f, long g, long h);
long w_narrow(int a, unsigned char b, short c, unsigned int d);
double w_mix(double x, float y, long k);
float w_half(float x);
void w_store(long *out, long value);
long w_late(long a, long b);
long w_call_binop(binop f, long a, long b);
long w_call_sum8(sum8 f);
long w_call_narrow(int (*f)(long), long x);
long w_call_byte(unsigned char (*f)(long), long x);
double w_call_mix(double (*f)(double, float, long));
long w_c_through_locals(long a, long b);
binop w_pick(long which);
long w_self_indirect(long a);
long w_ops_run(struct w_ops *ops);
void w_ops_fill(struct w_ops *ops);
long w_private_total_value(void);
extern long w_calls;
extern binop w_table_add, w_table_hidden, w_table_c_sub, w_table_late;
extern sum8 w_table_weigh8;

long c_sub(long a, long b) { return a - b; }

long c_weigh8(long a, long b, long c, long d, long e, long f, long g, long h) {
	return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h;
}

static long c_mul(long a, long b) { return a * b; }

/* Narrow results: the upper bits of rax are not part of the value. */
static int c_negate(long x) { return -(int)x; }
static unsigned char c_low_byte(long x) { return (unsigned char)x; }
static double c_mix(double x, float y, long k) { return x * y + k; }

/* Records with float members: SSE eightbytes. */
struct fpair { double x, y; };
struct mixed { double f; long i; };
struct imixed { long i; float f, g; };
struct fpair w_make_fpair(double x, double y);
struct mixed w_make_mixed(double f, long i);
struct imixed w_make_imixed(long i, float f);
double w_float_records(struct fpair p, struct mixed m, struct imixed q);
double w_call_float_records(struct mixed (*make)(double, long));
double c_float_records(struct fpair p, struct mixed m, struct imixed q) { return p.x + p.y * 10 + m.f * 100 + m.i * 1000 + q.i * 10000 + q.f * 100000 + q.g * 1000000; }
static struct mixed c_make_mixed(double f, long i) { struct mixed m = {f, i}; return m; }

static int failures;

static void check(const char *what, long got, long want) {
	if (got != want) {
		printf("FAIL %s: got %ld want %ld\n", what, got, want);
		failures++;
	}
}

int main(void) {
	long cell = 0;
	struct w_ops ops = {c_mul, w_add, c_weigh8};
	struct w_ops filled = {0, 0, 0};

	/* C calls W by name. */
	check("w_add", w_add(40, 2), 42);
	check("w_calls", w_calls, 1);
	check("w_weigh8", w_weigh8(1, 2, 3, 4, 5, 6, 7, 8), 87654321);
	check("w_narrow", w_narrow(-5, 200, -300, 4000000000u), 3999999895L);
	check("w_mix", (long)(w_mix(2.5, 4.0f, 7) * 2), 34);
	check("w_half", (long)(w_half(9.0f) * 2), 9);
	w_store(&cell, 99);
	check("w_store", cell, 99);

	/* C calls through the W object's static function-pointer table. */
	check("table add", w_table_add(1, 2), 3);
	check("table hidden", w_table_hidden(10, 4), 6);
	check("table c_sub", w_table_c_sub(10, 3), 7);
	check("table c_sub is c_sub", w_table_c_sub == c_sub, 1);
	check("table late", w_table_late(4, 2), 402);
	check("table weigh8", w_table_weigh8(8, 7, 6, 5, 4, 3, 2, 1), 12345678);
	check("table add is w_add", w_table_add == w_add, 1);

	/* W calls C callbacks (and W functions) through pointers. */
	check("w_call_binop c_mul", w_call_binop(c_mul, 6, 7), 42);
	check("w_call_binop w_mul", w_call_binop(w_mul, 6, 7), 42);
	check("w_call_binop table hidden", w_call_binop(w_table_hidden, 9, 2), 7);
	check("w_call_sum8 c_weigh8", w_call_sum8(c_weigh8), 204);
	check("w_call_sum8 w_weigh8", w_call_sum8(w_weigh8), 87654321);
	check("w_call_narrow", w_call_narrow(c_negate, 7), -7);
	check("w_call_byte", w_call_byte(c_low_byte, 0x1ff), 255);
	check("w_call_mix", (long)(w_call_mix(c_mix) * 2), 12);
	check("w_c_through_locals", w_c_through_locals(10, 4), 15);

	/* W returns System V pointers to W and C functions. */
	check("w_pick add", w_pick(0)(20, 22), 42);
	check("w_pick add is w_add", w_pick(0) == w_add, 1);
	check("w_pick mul", w_pick(1)(6, 7), 42);
	check("w_pick hidden", w_pick(2)(50, 8), 42);
	check("w_pick c_sub", w_pick(3) == c_sub, 1);
	check("w_self_indirect", w_self_indirect(9), 81);

	/* Tables of pointers filled on either side. */
	check("w_ops_run", w_ops_run(&ops), 2 + 7 + 36);
	w_ops_fill(&filled);
	check("filled add", filled.add(2, 3), 5);
	check("filled mul (c_sub)", filled.mul(9, 5), 4);
	check("filled sum", filled.sum(1, 1, 1, 1, 1, 1, 1, 1), 11111111);
	check("w_private_total", w_private_total_value(), 6 + 7 + 42);

	struct fpair fp = w_make_fpair(1.5, 2.5);
	check("w_make_fpair", (long)(fp.x * 10 + fp.y * 100), 265);
	struct mixed mx = w_make_mixed(0.5, 7);
	check("w_make_mixed", (long)(mx.f * 10) + mx.i * 100, 705);
	struct imixed im = w_make_imixed(3, 0.25f);
	check("w_make_imixed", im.i * 100 + (long)(im.f * 100) + (long)(im.g * 1000), 300 + 25 + 500);
	struct fpair p1 = {1, 2};
	struct mixed m1 = {3, 4};
	struct imixed q1 = {5, 6, 7};
	check("w_float_records", (long)w_float_records(p1, m1, q1), (long)c_float_records(p1, m1, q1));
	check("w_call_float_records", (long)w_call_float_records(c_make_mixed), (long)(2.5 * 2 + 9));

	if (failures == 0) printf("c abi object OK\n");
	return failures != 0;
}
