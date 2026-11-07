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

long c_data = 33;

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
	for (int i = 0; i < 64; i++)
		check("zero", w_zero[i], 0);
	if (failures == 0)
		printf("static data OK\n");
	return failures != 0;
}
