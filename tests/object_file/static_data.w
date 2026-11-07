# Static C-layout data in a freestanding object (tests/object_file_test.w):
# brace initializers (grammar/program.w, global_brace_initializer) lay
# out each global byte for byte, so the C host reads the same structs,
# arrays of structs, unions, bitfield words, pointer tables and strings
# a C compiler would have emitted, with nothing run at startup.
extern int c_data
# A C array ('int c_numbers[3]'): W indexes it through a header of its
# own, and a pointer to it is the C symbol.
extern int32[3] c_numbers

int w_handler(int x);

# struct entry { short kind; char flag; int count; long *ref; const char *name; }
struct entry:
	int16 kind
	int8 flag
	uint8 pad0
	int32 count
	int* ref
	char* name

int w_scalar = 11

# A fixed array's symbol names its elements, so C sees 'struct entry[3]';
# W code indexes it through the header just before them.
entry[3] w_entries = {
	int16 1, int8 -1, pad 1, int32 100, &w_scalar, c"first",
	int16 2, int8 0, pad 1, int32 -5, &c_data, c"second",
	int16 3, int8 0, pad 1, int32 0, &w_late}

# struct ops { long (*fn)(long); void *self; long *mid; }
# A function word holds the address the W global address initializers
# store for that function (docs/projects/object_files.md).
struct ops:
	int fn_word
	int self
	int mid

ops w_ops = {w_handler, &w_ops, &w_entries + 28}

# union { unsigned u; unsigned char b[4]; } initialized through its
# first member; then a 'unsigned a:3, b:5' bitfield unit and a 64-bit
# value wider than a 32-bit constant, as two halves.
struct misc:
	uint32 u
	uint32 bits
	uint32 lo
	uint32 hi
	uint8 c0
	uint8 c1
	uint8 c2
	uint8 c3

misc w_misc = {uint32 0x04030201, uint32 141, uint32 -1, uint32 1, uint8 'a', uint8 'b', uint8 'c'}

# Zero-initialized C-layout storage (a 'char buf[64]' with no initializer)
struct buffer:
	uint64 w0
	uint64 w1
	uint64 w2
	uint64 w3
	uint64 w4
	uint64 w5
	uint64 w6
	uint64 w7

buffer w_zero = {}


# Declared after the table that points at it
int w_late = 99


int w_handler(int x):
	return x + 1


export int w_entry_count(int i):
	return w_entries[i].count


int32[5] w_primes = {int32 2, int32 3, int32 5, int32 7}


export int w_prime(int i):
	return w_primes[i]


int* w_number_ref = &c_numbers + 8


export int w_numbers_sum():
	int sum = 0
	for i in range(c_numbers.length): sum = sum + c_numbers[i]
	c_numbers[0] = 40
	return sum
