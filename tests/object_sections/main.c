/* Host for tests/object_sections/library.w: checks every placement and
   attribute from C after the link (tests/object_sections_test.w). */
#include <stdio.h>
#include <string.h>

long w_init_first(void);
long w_run_initcalls(void);
long w_weak_hook(void);
long w_uses_hook(void);
long w_real(long);
long w_real_alias(long);
long w_call_alias(long);
long w_has_optional(void);
long w_cache_line_address(void);
long w_page_table_address(void);
long w_greeting_length(void);
extern long w_answer, w_zero_counter, w_counter, w_counter_alias;
extern long __w_table_start[], __w_table_end[];
extern void *__w_initcalls_start[], *__w_initcalls_end[];

#ifdef STRONG
long w_weak_hook(void) { return 9; }
#define HOOK 9
#else
#define HOOK 5
#endif

static int failures;
static char notes[256];

void c_note(const char *text, long value) {
	char line[64];
	snprintf(line, sizeof line, "%s=%ld;", text, value);
	strncat(notes, line, sizeof notes - strlen(notes) - 1);
}

static void check(const char *what, long got, long want) {
	if (got != want) {
		printf("FAIL %s: got %ld, want %ld\n", what, got, want);
		failures++;
	}
}

int main(void) {
	long sum = 0;
	for (long *p = __w_table_start; p < __w_table_end; p++) sum += *p;
	check("table entries", __w_table_end - __w_table_start, 2);
	check("table sum", sum, 42);
	check("initcall entries", __w_initcalls_end - __w_initcalls_start, 2);
	/* level 1 (w_init_helper(1) = 1 + 7), then level 6 (w_init_second(9)
	   returns 2): 8 * 100 + 2 */
	check("initcalls run in level order", w_run_initcalls(), 802);
	check("init first", w_init_first(), 16);
	check("notes", strcmp(notes, "init second=9;init first=8;"), 0);
	check("weak hook from C", w_weak_hook(), HOOK);
	check("weak hook from W", w_uses_hook(), 105);
	check("alias", w_real_alias(4), 12);
	check("alias from W", w_call_alias(4), 13);
	check("weak undefined data", w_has_optional(), 0);
	check(".rodata global", w_answer, 42);
	check(".bss global", w_zero_counter, 0);
	check(".data global", w_counter, 7);
	check("data alias", &w_counter_alias == &w_counter, 1);
	check("64-byte alignment", w_cache_line_address() % 64, 0);
	check("page alignment", w_page_table_address() % 4096, 0);
	check("literal in .rodata", w_greeting_length(), 17);
	if (failures) return 1;
	printf("object sections OK\n");
	return 0;
}
