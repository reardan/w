/* C host for tests/object_file/library.w: links the W object with the
   system C compiler and checks every crossing in both directions. A W
   int is 64 bits on x64, so the C side uses long. */
#include <stdio.h>
#include <string.h>

long w_add(long a, long b);
long w_sum(long *xs, long n);
void w_fill(long *out, long n);
long w_call_c(long x);
long w_apply(long which, long x);
long w_squares_sum(void);
char *w_greeting(void);
long *w_counter_address(void);
long w_c_value_through_cell(void);
long w_literal_length(void);
extern long w_counter;

long c_value = 100;
static char recorded[64];
static long recorded_value;

long c_scale(long x) { return x * 5; }

void c_record(char *text, long value) {
	strncpy(recorded, text, sizeof recorded - 1);
	recorded_value = value;
}

static int failures;

static void check(const char *what, long got, long want) {
	if (got != want) {
		printf("FAIL %s: got %ld want %ld\n", what, got, want);
		failures++;
	}
}

int main(void) {
	long xs[5] = {1, 2, 3, 4, 5};
	long out[4] = {0};
	check("w_counter initial", w_counter, 7);
	check("w_add", w_add(40, 2), 42);
	check("w_counter after add", w_counter, 8);
	w_counter = 20;
	check("w_counter_address", *w_counter_address(), 20);
	check("w_counter_address is &w_counter", w_counter_address() == &w_counter, 1);
	check("w_sum", w_sum(xs, 5), 15);
	w_fill(out, 4);
	check("w_fill", out[0] + out[1] + out[2] + out[3], 14);
	check("w_call_c", w_call_c(3), 115);
	check("c_value written by W", c_value, 115);
	check("c_record value", recorded_value, 15);
	check("c_record text", strcmp(recorded, "hello from W"), 0);
	check("w_apply double", w_apply(0, 21), 42);
	check("w_apply triple", w_apply(1, 14), 42);
	check("w_apply C via W pointer", w_apply(2, 4), 20);
	check("w_squares_sum", w_squares_sum(), 30);
	check("w_greeting", strcmp(w_greeting(), "hello from W"), 0);
	c_value = 77;
	check("w_c_value_through_cell", w_c_value_through_cell(), 77);
	check("w_literal_length", w_literal_length(), 17);
	if (failures == 0) printf("object file OK\n");
	return failures != 0;
}
