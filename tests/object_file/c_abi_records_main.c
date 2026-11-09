/* C driver for tests/object_file/c_abi_records.w (--c-abi records,
   C-variadic definitions, wide signatures, unsized extern arrays). */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

struct pair { long a, b; };
struct small { int x, y; };
struct tiny { unsigned char c; };
struct big { long a, b, c, d; };
union word_or_bytes { long w; unsigned char b; };

long w_sum_pair(struct pair p);
long w_sum_records(struct pair p, struct small s, struct big g, struct tiny t, long k);
struct pair w_make_pair(long a, long b);
struct small w_make_small(long x, long y);
struct tiny w_make_tiny(long c);
struct big w_make_big(long seed);
long w_union_word(union word_or_bytes u);
long w_late_record(long a, long b, long c, long d, long e, struct pair p, struct pair q);
long w_twelve(long a, long b, long c, long d, long e, long f, long g, long h, long i, long j, long k, signed char l);
long w_calls_c(void);
long w_calls_pointers(struct pair (*make)(long, long), struct big (*make_big)(long), long (*take)(struct pair, struct big, long));
long w_vsum(long n, ...);
long w_vrecords(long n, ...);
long w_vcalls(void);
long w_vrecord_calls(void);
long w_numbers(long i);
unsigned char *w_bytes_at(long i);
long w_arrays_apart(void);

int c_numbers[] = {7, 11, 13, 17, 19};
unsigned char c_bytes[] = "abcdef";

struct pair c_make_pair(long a, long b) { struct pair p = {a, b}; return p; }
struct big c_make_big(long seed) { struct big g = {seed, seed + 1, seed + 2, seed + 3}; return g; }
long c_sum_records(struct pair p, struct small s, struct big g, struct tiny t, long k)
{
	return p.a + 10 * p.b + 100 * s.x + 1000 * s.y + 10000 * g.a + 100000 * g.d + 1000000 * t.c + 10000000 * k;
}
long c_vsum(long n, va_list ap)
{
	long total = 0;
	for (long i = 0; i < n; i++) total += va_arg(ap, long);
	return total;
}
long c_printf_like(long n, ...)
{
	va_list ap;
	va_start(ap, n);
	long total = c_vsum(n, ap);
	va_end(ap);
	return total;
}
long c_tagged_vsum(struct pair p, long n, ...)
{
	va_list ap;
	va_start(ap, n);
	long total = p.a + 10 * p.b + c_vsum(n, ap);
	va_end(ap);
	return total;
}
long c_vrecord_tail(long n, ...)
{
	va_list ap;
	va_start(ap, n);
	struct pair p = va_arg(ap, struct pair);
	struct big g = va_arg(ap, struct big);
	struct small s = va_arg(ap, struct small);
	va_end(ap);
	return n + p.a * 10 + p.b * 20 + g.a + g.d * 10 + s.x + s.y * 100;
}
static long take3(struct pair p, struct big g, long k) { return p.a + p.b * 10 + g.a * 100 + g.d * 1000 + k * 100000; }

static int failures;
static void check(const char *what, long got, long want)
{
	if (got != want) {
		printf("FAIL %s: got %ld want %ld\n", what, got, want);
		failures++;
	}
}

int main(void)
{
	struct pair p = {2, 5};
	struct small s = {3, 4};
	struct big g = {6, 7, 8, 9};
	struct tiny t = {1};
	check("sum_pair", w_sum_pair(p), 7);
	check("sum_records", w_sum_records(p, s, g, t, 2), c_sum_records(p, s, g, t, 2));
	struct pair mp = w_make_pair(-1, 1L << 40);
	check("make_pair", mp.a + (mp.b >> 40), 0);
	struct small ms = w_make_small(-3, 4);
	check("make_small", ms.x * 10 + ms.y, -26);
	check("make_tiny", w_make_tiny(200).c, 200);
	struct big mb = w_make_big(100);
	check("make_big", mb.a + mb.b * 10 + mb.c * 100 + mb.d * 1000, 100 + 1010 + 10200 + 103000);
	union word_or_bytes u = {.w = 99};
	check("union", w_union_word(u), 99);
	struct pair q = {3, 4};
	check("late_record", w_late_record(1, 2, 3, 4, 5, p, q), 15 + 20 + 500 + 3000 + 40000);
	check("twelve", w_twelve(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, -2), 55 + 11000 - 200000);
	check("calls_c", w_calls_c(), 3 + 40 + 1000 + 13000 + c_sum_records((struct pair){3, 4}, (struct small){5, 6}, c_make_big(10), (struct tiny){7}, 9) * 10000);
	check("calls_pointers", w_calls_pointers(c_make_pair, c_make_big, take3), 1 + 20 + 2000 + 23000 + 300000 + 2000000);
	check("vsum", w_vsum(3, 10L, 20L, 30L), 60);
	check("vsum_stack", w_vsum(8, 1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L), 36);
	long (*vp)(long, ...) = w_vsum;
	check("vsum_pointer", vp(2, 5L, 6L), 11);
	check("vrecords", w_vrecords(2, p, g, 4L, 5L), 2 + 50 + 900 + 9000 + 500000);
	check("vcalls", w_vcalls(), 6 + 110);
	check("vrecord_calls", w_vrecord_calls(), 1 + 20 + 30 + 1000 * (9 + 10 + 40 + 3 + 60 + 7 + 800));
	check("numbers", w_numbers(4), 19);
	check("bytes", *w_bytes_at(5), 'f');
	check("arrays_apart", w_arrays_apart(), (char *)c_bytes - (char *)c_numbers);
	if (failures == 0) printf("c abi records OK\n");
	return failures != 0;
}
