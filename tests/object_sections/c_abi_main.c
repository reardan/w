/* Host for tests/object_sections/c_abi_library.w (--c-abi): calls the
   initcall table and the weak and alias symbols from C
   (tests/object_sections_test.w). */
#include <stdio.h>

typedef long (*initcall_t)(long);
extern initcall_t __w_initcalls_start[], __w_initcalls_end[];
extern long __w_table_start[], __w_table_end[];
long init_level1(long);
long weak_hook(long);
long call_hook(long);
long real(long);
long real_alias(long);
long call_alias(long);

#ifdef STRONG
long weak_hook(long x) { return x + 9; }
#define HOOK 9
#else
#define HOOK 5
#endif

static int failures;

static void check(const char *what, long got, long want) {
	if (got != want) {
		printf("FAIL %s: got %ld, want %ld\n", what, got, want);
		failures++;
	}
}

int main(void) {
	long total = 0;
	check("initcall entries", __w_initcalls_end - __w_initcalls_start, 2);
	for (initcall_t *f = __w_initcalls_start; f < __w_initcalls_end; f++) total = total * 1000 + (*f)(1);
	/* level 1: (1 + 7) * 2 = 16; level 6: 16 + 1 + 100 = 117 */
	check("initcalls in level order", total, 16117);
	check("table", __w_table_end - __w_table_start, 2);
	check("table sum", __w_table_start[0] + __w_table_start[1], 42);
	check("weak from C", weak_hook(1), 1 + HOOK);
	check("weak through a W pointer", call_hook(1), (1 + HOOK) * 1000 + 6);
	check("alias from C", real_alias(4), 12);
	check("alias address", real_alias == real, 1);
	check("alias from W", call_alias(4), 24);
	if (failures) return 1;
	printf("object sections c-abi OK\n");
	return 0;
}
