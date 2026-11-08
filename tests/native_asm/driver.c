/*
 * C driver for the native inline-asm object (tests/native_asm/ops.w),
 * built by gcc. Each W function is checked against the same operation
 * written in C inline asm or a GCC builtin. Exit 0 = every check passed.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

extern void w_cpuid(int leaf, int *a, int *b, int *c, int *d);
extern int w_xchg(int *p, int newv);
extern int w_cmpxchg(int *p, int expected, int newv, int *okflag);
extern int w_xadd(int *p, int add);
extern int w_rdtsc_lo(void);
extern int w_fetch_add64(int *p, int add);
extern int w_low_byte(int v);
extern int w_low_word(int v);
extern int w_inc_byte(int *p);
extern int w_sum_to(int n);
extern int w_relabel(void);
extern int w_call_c(int a);
extern int w_bump_counter(int add, int *address_ok);
extern int w_probe(int *p, int64_t *fault_site);
extern void w_misc_marker(void);
extern int w_lock_add(int *p, int add);

/* Called from w_call_c's template; read by w_bump_counter's. */
int c_counter = 40;
long c_triple(long a) { return 3 * a + 1; }

/* The exception table the templates emit: pairs of self-relative
 * offsets (faulting instruction, fixup), bounded by the linker's
 * __start_/__stop_ symbols, and the absolute site addresses. */
struct w_extable_entry { int32_t insn, fixup; };
extern const struct w_extable_entry __start_w_extable[], __stop_w_extable[];
extern const uint64_t __start_w_sites[], __stop_w_sites[];
extern const unsigned char __start_w_misc[], __stop_w_misc[];
extern const int64_t __start_w_more[], __stop_w_more[];

static uintptr_t extable_fixup(uintptr_t rip)
{
	for (const struct w_extable_entry *e = __start_w_extable; e < __stop_w_extable; e++) {
		uintptr_t insn = (uintptr_t)&e->insn + e->insn;
		if (insn == rip) return (uintptr_t)&e->fixup + e->fixup;
	}
	return 0;
}

static int faults_fixed = 0;

static void on_segv(int sig, siginfo_t *info, void *context)
{
	ucontext_t *uc = context;
	uintptr_t fixup = extable_fixup((uintptr_t)uc->uc_mcontext.gregs[REG_RIP]);
	(void)sig; (void)info;
	if (fixup == 0) { static const char m[] = "unexpected fault\n"; (void)!write(1, m, sizeof m - 1); _exit(3); }
	uc->uc_mcontext.gregs[REG_RIP] = (greg_t)fixup;
	faults_fixed++;
}

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

	/* Local labels and branches. */
	CHECK(w_sum_to(10) == 55, "sum_to loop with local labels");
	CHECK(w_sum_to(0) == 0, "sum_to zero iterations");
	CHECK(w_relabel() == 2, "numeric labels redefined");

	/* A call to a C function from the template. */
	CHECK(w_call_c(5) == 16, "template calls a C function");
	CHECK(w_call_c(-2) == -5, "template call, negative argument");

	/* RIP-relative and absolute symbol operands. */
	int same = -1;
	c_counter = 40;
	CHECK(w_bump_counter(2, &same) == 40, "rip-relative symbol load");
	CHECK(c_counter == 43, "rip-relative symbol stores");
	CHECK(same == 1, "lea sym(%rip) == $sym");

	/* The exception table: one record per probe site. */
	CHECK(__stop_w_extable - __start_w_extable == 1, "one extable record");
	CHECK(__stop_w_sites - __start_w_sites == 1, "one site record");
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = on_segv;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, 0);
	int good = 1234;
	int64_t site = 0;
	CHECK(w_probe(&good, &site) == 1234, "probe reads a good pointer");
	CHECK(faults_fixed == 0, "no fault on a good pointer");
	CHECK(extable_fixup((uintptr_t)site) != 0, "extable names the probe site");
	CHECK((uint64_t)site == __start_w_sites[0], ".quad 1b is the site address");
	CHECK(w_probe((int *)0, &site) == -14, "probe fault resumes at the fixup");
	CHECK(faults_fixed == 1, "one fault fixed up");

	/* The data directives of w_misc. */
	const unsigned char *m = __start_w_misc;
	CHECK(__stop_w_misc - __start_w_misc == 24, "w_misc size");
	CHECK(m[0] == 0x11 && m[1] == 0x22 && m[2] == 0 && m[3] == 0, ".byte and .balign");
	CHECK(m[4] == 0x44 && m[5] == 0x33 && m[6] == 0xee && m[7] == 0xee, ".word and .balign fill");
	int64_t diff;
	memcpy(&diff, m + 8, 8);
	CHECK(diff == 6, ".quad label difference");
	uint32_t abs32;
	memcpy(&abs32, m + 16, 4);
	CHECK(abs32 == (uint32_t)(uintptr_t)&c_counter, ".long symbol (R_X86_64_32)");
	int32_t rel32;
	memcpy(&rel32, m + 20, 4);
	CHECK((uintptr_t)(m + 20) + rel32 == (uintptr_t)&c_triple, ".long symbol - . (R_X86_64_PC32)");
	w_misc_marker();

	/* A lone lock prefix, .section/.previous and a PC64 value. */
	int la = 10;
	CHECK(w_lock_add(&la, 5) == 10 && la == 15, "lock; xadd");
	CHECK(__stop_w_more - __start_w_more == 1, "w_more size");
	CHECK((uintptr_t)__start_w_more + __start_w_more[0] == (uintptr_t)&c_triple, ".quad symbol - . (R_X86_64_PC64)");

	if (fails == 0) printf("native_asm driver: all checks passed\n");
	return fails == 0 ? 0 : 1;
}
