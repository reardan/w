/* C side of tests/kernel_codegen/validator.w: the kernel's return and
   indirect-branch thunks (counting the returns that reach the first),
   the variadic and wide callees, and a check of kv_run's result. */
#include <stdarg.h>
#include <stdio.h>

long kv_thunk_returns;
__asm__(".text\n"
	".globl __x86_return_thunk\n"
	"__x86_return_thunk:\n"
	"\tincq kv_thunk_returns(%rip)\n"
	"\tret\n"
	".globl __x86_indirect_thunk_r11\n"
	"__x86_indirect_thunk_r11:\n"
	"\tjmp *%r11\n"
	".globl __x86_indirect_thunk_rax\n"
	"__x86_indirect_thunk_rax:\n"
	"\tjmp *%rax\n");

long kv_run(long x);

long kv_c_sum(long n, ...)
{
	va_list ap;
	long total = 0;
	va_start(ap, n);
	for (long i = 0; i < n; i++)
		total += va_arg(ap, long);
	va_end(ap);
	return total;
}

long kv_c_wide(long a, long b, long c, long d, long e, long f, long g, long h)
{
	return a * 100 + b + c + d + e + f + g + h * 10;
}

int main(int argc, char **argv)
{
	(void)argv;
	long x = 4 + argc;   /* 5 */
	long want = x * 3 + (1 + 4 + 9 + 16 + 25 + 36 + 49 + x * 8) + (36 + x) + (x * 100 + 6 + 20) + 5 + 100;
	long got = kv_run(x);
	printf("validator %ld %ld returns %s\n", got, want, kv_thunk_returns > 0 ? "thunked" : "plain");
	return got == want ? 0 : 1;
}
