/* Exercises the c_import constant-expression evaluator and declarator
   handling: negative values, precedence, ternaries, sizeof, references to
   earlier enumerators, padded struct layout, arrays, function pointers. */

enum ci_eval_levels {
	CI_NEG = -3,
	CI_NEXT,
	CI_SHIFTED = 1 << 4,
	CI_MIXED = 2 + 3 * 4,
	CI_TERNARY = 0 ? 9 : 7,
	CI_REF = CI_SHIFTED + 1,
	CI_HEX_MASK = (0xff & 0x1f) | 0x40,
	CI_SIZEOF_INT = sizeof(int),
	CI_SIZEOF_PTR = sizeof(char *),
	CI_CAST = (int) sizeof(unsigned short),
};

struct ci_eval_sizes {
	char tag;
	int value;
	unsigned char bytes[3 + sizeof(int)];
	short tail;
};

typedef struct ci_eval_sizes ci_eval_sizes_t;

typedef int (*ci_eval_callback)(int code, const char *message);

extern int ci_eval_unused(void (*callback)(int, char *), const void *data, char name[8]);
