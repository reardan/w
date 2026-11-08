/* C host for tests/object_file/static_data.w: reads the W object's static
   data through the C declarations a C compiler would lay out the same
   way, and checks sizes and offsets against the compiler's own. */
#include <stddef.h>
#include <stdio.h>
#include <string.h>

struct entry {
	short kind;
	char flag;
	int count;
	long *ref;
	const char *name;
};

struct ops {
	long (*fn)(long);
	void *self;
	long *mid;
};

union word {
	unsigned u;
	unsigned char b[4];
};

struct misc {
	union word w;
	unsigned a : 3, b : 5;
	unsigned long long big;
	char text[4];
};

extern struct entry w_entries[3];
extern struct ops w_ops;
extern struct misc w_misc;
extern char w_zero[64];
extern long w_scalar;
long w_entry_count(long i);
extern int w_primes[5];
long w_prime(long i);

long c_data = 33;
int c_numbers[3] = {5, 6, 7};
extern int *w_number_ref;
extern int *w_numbers_end;
extern int *w_numbers_bounds[2];
int c_squares[] = {0, 1, 4, 9, 16};
extern int *w_squares_ref;
extern int *w_squares_refs[2];
struct opaque { long payload; } c_opaque = {42};
extern struct opaque *w_opaque_ref;
extern int w_scratch[4];
extern int *w_scratch_end;
struct opaque *w_opaque_address(void);
long w_numbers_sum(void);

static int failures;

static void check(const char *what, long got, long want) {
	if (got != want) {
		printf("FAIL %s: got %ld want %ld\n", what, got, want);
		failures++;
	}
}

int main(void) {
	check("sizeof entry", sizeof(struct entry), 24);
	check("offsetof count", offsetof(struct entry, count), 4);
	check("offsetof ref", offsetof(struct entry, ref), 8);
	check("sizeof misc", sizeof(struct misc), 24);
	check("entries[0].kind", w_entries[0].kind, 1);
	check("entries[0].flag", w_entries[0].flag, -1);
	check("entries[0].count", w_entries[0].count, 100);
	check("entries[0].ref", *w_entries[0].ref, 11);
	check("entries[0].ref is &w_scalar", w_entries[0].ref == &w_scalar, 1);
	check("entries[0].name", strcmp(w_entries[0].name, "first"), 0);
	check("entries[1].count", w_entries[1].count, -5);
	check("entries[1].ref is &c_data", w_entries[1].ref == &c_data, 1);
	check("entries[1].name", strcmp(w_entries[1].name, "second"), 0);
	check("entries[2].kind", w_entries[2].kind, 3);
	check("entries[2].count", w_entries[2].count, 0);
	check("entries[2].ref", *w_entries[2].ref, 99);
	check("entries[2].name", w_entries[2].name == 0, 1);
	check("w_entry_count", w_entry_count(1), -5);
	check("ops.self", w_ops.self == &w_ops, 1);
	check("ops.mid", w_ops.mid == (long *)((char *)w_entries + 28), 1);
	check("ops.fn set", w_ops.fn != 0, 1);
	check("misc.w.b[0]", w_misc.w.b[0], 1);
	check("misc.w.b[3]", w_misc.w.b[3], 4);
	check("misc.a", w_misc.a, 5);
	check("misc.b", w_misc.b, 17);
	check("misc.big", w_misc.big == 0x1ffffffffULL, 1);
	check("misc.text", memcmp(w_misc.text, "abc", 4), 0);
	check("w_primes[3]", w_primes[3], 7);
	check("w_primes[4]", w_primes[4], 0);
	w_primes[4] = 11;
	check("w_prime(4)", w_prime(4), 11);
	check("extern array from W", w_numbers_sum(), 18);
	check("extern array written by W", c_numbers[0], 40);
	check("pointer into extern array", w_number_ref == &c_numbers[2], 1);
	check("pointer past extern array", w_numbers_end == c_numbers + 3, 1);
	check("brace pointer to extern array", w_numbers_bounds[0] == c_numbers, 1);
	check("brace pointer past extern array", w_numbers_bounds[1] == c_numbers + 3, 1);
	check("pointer to unsized extern array", w_squares_ref == c_squares, 1);
	check("brace pointer to unsized extern array", w_squares_refs[0] == c_squares, 1);
	check("brace pointer into unsized extern array", w_squares_refs[1] == &c_squares[2], 1);
	check("value through unsized extern pointer", *w_squares_refs[1], 4);
	check("pointer to a zero-size extern", w_opaque_ref == &c_opaque, 1);
	check("address of a zero-size extern", w_opaque_address() == &c_opaque, 1);
	check("value through it", w_opaque_ref->payload, 42);
	check("pointer past a W array", w_scratch_end == w_scratch + 4, 1);
	for (int i = 0; i < 64; i++)
		check("zero", w_zero[i], 0);
	if (failures == 0)
		printf("static data OK\n");
	return failures != 0;
}
