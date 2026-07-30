/* System-header torture shapes gathered from real-world headers:
   forward-declared struct typedefs, nested unions, anonymous inner
   structs, named and unnamed bit-fields, array and function-pointer
   fields, enum constant expressions, function typedefs, macro-sized
   extern arrays, and K&R declarations mixed with prototyped variadic
   ones. */

#define CI_TT_MAX 16

typedef unsigned long ci_tt_word;

struct ci_tt_node;
typedef struct ci_tt_node ci_tt_node_t;

struct ci_tt_node {
	struct ci_tt_node *next;
	union {
		int as_int;
		char as_bytes[8];
	} payload;
	unsigned int flags : 3;
	unsigned int : 2;
	int cells[2][2];
	int (*compare)(const void *left, const void *right);
	struct {
		short row;
		short col;
	} origin;
};

enum ci_tt_flags {
	CI_TT_A = 1 << 4,
	CI_TT_B = CI_TT_A | 3,
	CI_TT_C
};

typedef int ci_tt_handler();

extern ci_tt_node_t *ci_tt_head;
extern const char *const ci_tt_names[];
extern ci_tt_word ci_tt_masks[CI_TT_MAX];

int ci_tt_old();
long ci_tt_older(count, names);
int ci_tt_mixed(ci_tt_word w, const char *name, ...);

int ci_tt_defined(value)
	int value;
{
	if (value > 0)
		return value;
	return -value;
}
