/* Host for tests/object_sections/c_abi_library.w (--c-abi): calls the
   initcall table and the weak and alias symbols from C
   (tests/object_sections_test.w). */
#include <stdio.h>
#include <stdint.h>

typedef long (*initcall_t)(long);
extern initcall_t __w_initcalls_start[], __w_initcalls_end[];
extern long __w_table_start[], __w_table_end[];
long init_level1(long);
long weak_hook(long);
long call_hook(long);
long real(long);
long real_alias(long);
long call_alias(long);

struct ops { long (*run)(long); long (*later)(long); long (*from_c)(long); long *data; };
extern struct ops w_ops_table[2];
extern int w_vector[4];
extern int w_zero_array[16], w_plain_array[16];
long w_vector_sum(void);
long w_zero_sum(void);
long w_ops_call(long, long);
long c_scale(long x) { return x * 10; }

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
	check("weak through a W pointer and a W call", call_hook(1), (1 + HOOK) * 1000 + 1 + HOOK);
	check("alias from C", real_alias(4), 12);
	check("alias address", real_alias == real, 1);
	check("alias from W", call_alias(4), 24);
	check("ops run", w_ops_table[0].run(4), 12);
	check("ops forward function", w_ops_table[0].later(4), 3);
	check("ops extern function", w_ops_table[0].from_c(4), 40);
	check("ops data", *w_ops_table[0].data, 11);
	check("ops second entry", w_ops_table[1].run(1) + w_ops_table[1].later(1) + w_ops_table[1].from_c(1) + *w_ops_table[1].data, 16 + 3 + 0 + 31);
	check("ops entry is the function", w_ops_table[0].run == real, 1);
	check("ops table alignment", (uintptr_t)w_ops_table & 31, 0);
	check("ops from W", w_ops_call(0, 4), 12 + 3 + 40 + 11);
	check("vector alignment", (uintptr_t)w_vector & 63, 0);
	check("vector", w_vector[0] + w_vector[3], 5);
	w_vector[1] = 20;
	check("vector from W", w_vector_sum(), 1 + 20 + 3 + 4);
	w_zero_array[3] = 5;
	w_plain_array[15] = 6;
	check("zero arrays from W", w_zero_sum(), 11);
	if (failures) return 1;
	printf("object sections c-abi OK\n");
	return 0;
}
