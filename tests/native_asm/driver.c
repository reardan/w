/*
 * C driver for the native inline-asm object (tests/native_asm/ops.w),
 * built by gcc. Each W function is checked against the same operation
 * written in C inline asm or a GCC builtin. Exit 0 = every check passed.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

extern void w_cpuid(int leaf, int *a, int *b, int *c, int *d);
extern int w_xchg(int *p, int newv);
extern int w_cmpxchg(int *p, int expected, int newv, int *okflag);
extern int w_xadd(int *p, int add);
extern int w_rdtsc_lo(void);
extern int w_fetch_add64(int *p, int add);
extern int w_low_byte(int v);
extern int w_low_word(int v);
extern int w_inc_byte(int *p);

static int fails = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } } while (0)

static void c_cpuid(int leaf, unsigned *a, unsigned *b, unsigned *c, unsigned *d)
{
	unsigned ra, rb, rc, rd;
	__asm__ volatile("cpuid"
		: "=a"(ra), "=b"(rb), "=c"(rc), "=d"(rd)
		: "a"(leaf), "c"(0));
	*a = ra; *b = rb; *c = rc; *d = rd;
}

int main(void)
{
	/* CPUID leaf 0: vendor string in ebx,edx,ecx, max leaf in eax. */
	int wa, wb, wc, wd;
	unsigned ca, cb, cc, cd;
	w_cpuid(0, &wa, &wb, &wc, &wd);
	c_cpuid(0, &ca, &cb, &cc, &cd);
	CHECK((unsigned)wa == ca && (unsigned)wb == cb &&
	      (unsigned)wc == cc && (unsigned)wd == cd, "cpuid leaf 0");

	/* CPUID leaf 1: feature flags. */
	w_cpuid(1, &wa, &wb, &wc, &wd);
	c_cpuid(1, &ca, &cb, &cc, &cd);
	CHECK((unsigned)wc == cc && (unsigned)wd == cd, "cpuid leaf 1 features");

	/* xchg. */
	int cell = 100;
	int old = w_xchg(&cell, 250);
	CHECK(old == 100, "xchg returns previous");
	CHECK(cell == 250, "xchg stores new");

	/* cmpxchg success and failure, with the flag output. */
	int cx = 7, okflag = -1;
	int prev = w_cmpxchg(&cx, 7, 42, &okflag);
	CHECK(prev == 7, "cmpxchg success returns old");
	CHECK(cx == 42, "cmpxchg success stores");
	CHECK(okflag == 1, "cmpxchg success flag set");
	okflag = -1;
	prev = w_cmpxchg(&cx, 7, 99, &okflag);     /* cx is now 42, not 7 */
	CHECK(prev == 42, "cmpxchg fail returns current");
	CHECK(cx == 42, "cmpxchg fail no store");
	CHECK(okflag == 0, "cmpxchg fail flag clear");

	/* xadd. */
	int counter = 1000;
	int before = w_xadd(&counter, 23);
	CHECK(before == 1000, "xadd returns previous");
	CHECK(counter == 1023, "xadd accumulates");

	/* rdtsc: monotonic across two reads (low 32 bits may wrap, so just
	 * require it changes / is plausibly nonzero over a short loop). */
	unsigned t1 = (unsigned)w_rdtsc_lo();
	for (volatile int i = 0; i < 100000; i++) { }
	unsigned t2 = (unsigned)w_rdtsc_lo();
	CHECK(t1 != 0 || t2 != 0, "rdtsc nonzero");
	CHECK(t1 != t2, "rdtsc advances");


	/* inout width 8 + clobber. */
	int fa = 500;
	int faold = w_fetch_add64(&fa, 11);
	CHECK(faold == 500, "fetch_add64 returns old");
	CHECK(fa == 511, "fetch_add64 adds in place");

	/* width-1 store: only the low byte of out is overwritten. */
	int lb = w_low_byte(0x11223344);
	CHECK((lb & 0xff) == 0x44, "low_byte stores low 8 bits");
	CHECK(((unsigned)lb & 0xffffff00) == (1234u & 0xffffff00), "low_byte keeps upper bytes");

	/* width-2 store: low 16 bits of out overwritten. */
	int lw = w_low_word(0xaabbccdd);
	CHECK((lw & 0xffff) == 0xccdd, "low_word stores low 16 bits");
	CHECK(((unsigned)lw & 0xffff0000) == 0x5a5a0000u, "low_word keeps upper half");

	/* inout width 1: load low byte of *p into a 4-byte output (zero-ext). */
	int bp = 0x77;
	int seen = w_inc_byte(&bp);
	CHECK(seen == 0x77, "inc_byte zero-extends loaded byte");

	if (fails == 0) printf("native_asm driver: all checks passed\n");
	return fails == 0 ? 0 : 1;
}
