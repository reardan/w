/* Bit-field layout battery for the c_import bit-field fixtures and the
   x64 run test (tests/x64_c_import_bitfield_test.w). Every size and
   offset here is pinned against gcc/clang for both the i386 and x86-64
   System V ABIs: storage-unit packing, the no-excess-unit-span straddle
   rule, ':0' closing the declared type's unit, unnamed bit-fields
   (which allocate bits but do not affect struct alignment), bit-fields
   of typedef and enum type, mixing with plain members, tail padding,
   and bit-fields in unions. */

struct ci_bf_basic {
	char a;
	unsigned int b : 3;
	unsigned int c : 5;
	char d;
};

struct ci_bf_zero {
	char a;
	int : 0;
	char b;
};

struct ci_bf_straddle {
	unsigned int a : 30;
	unsigned int b : 4;
	char c;
};

struct ci_bf_unnamed {
	char a;
	unsigned int : 24;
	char b;
};

struct ci_bf_short {
	char a;
	unsigned short b : 9;
	char c;
};

struct ci_bf_wide {
	unsigned long long a : 33;
	char b;
};

struct ci_bf_span {
	unsigned int a : 30;
	unsigned long long b : 40;
	char c;
};

struct ci_bf_pack {
	char c;
	unsigned long long b : 40;
};

struct ci_bf_mixed {
	short s;
	int b : 24;
	char c;
};

typedef unsigned short ci_bf_u16;

struct ci_bf_typedef {
	ci_bf_u16 a : 4;
	ci_bf_u16 b : 13;
	char c;
};

enum ci_bf_mode { CI_BF_M0, CI_BF_M1, CI_BF_M2 };

struct ci_bf_enum {
	enum ci_bf_mode mode : 2;
	unsigned int rest : 30;
	short v;
};

struct ci_bf_tail {
	int a;
	unsigned int b : 3;
};

struct ci_bf_llzero {
	char c;
	long long : 0;
	char d;
};

union ci_bf_union {
	char c;
	unsigned int b : 3;
};

union ci_bf_union_wide {
	unsigned long long b : 1;
};

/* Signed vs unsigned bit-fields: reads sign-extend per the declared
   type; writes truncate to the width (gcc behavior on both ABIs). */
struct ci_bf_signed {
	int a : 3;
	int b : 5;
	unsigned int c : 3;
	int d : 21;
};

/* Signed/unsigned long long fields sharing an 8-byte unit, plus an int
   field opening the next unit. On i386 'a' (width 40) has no word-sized
   load window, so member access stays a compile error there; 'b' and
   'c' are accessible on both targets. */
struct ci_bf_sll {
	long long a : 40;
	unsigned long long b : 24;
	int c : 20;
};

/* Signed short bit-fields with negative values. */
struct ci_bf_s16 {
	short a : 9;
	short b : 7;
	unsigned short c : 10;
};

/* Signed and unsigned views of the same union bits. */
union ci_bf_su {
	int s : 5;
	unsigned int u : 5;
};
