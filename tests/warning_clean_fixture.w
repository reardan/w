# Cleanly typed program: the warning_test build target (via
# bin/wfixture) asserts that compiling this file produces no warnings
# on stderr.
# reject_stderr: warning:
import lib.lib


struct pair:
	int a
	int b


int add(int a, int b):
	return a + b


char* first_string(char* s):
	return s


int pair_sum(pair* p):
	return p.a + p.b


# cast() is the escape hatch: every conversion the checks would reject
# compiles silently when spelled explicitly.
int cast_escape_hatches():
	char* buffer = malloc(8)
	int word = cast(int, buffer)      /* pointer -> int */
	char* back = cast(char*, word)    /* int -> pointer */
	int* words = cast(int*, buffer)   /* pointer -> pointer */
	int fn_word = cast(int, add)      /* function -> int */
	free(back)
	return fn_word + cast(int, words)


# Array-to-pointer decay is warning-free in every direction of a
# conditional, and cast(int, arr) decays like cast(char*, arr) (#229)
int array_decay_is_clean(int flag):
	char[8] cells
	cells[0] = 'c'
	char* p = cells
	char* then_arm = flag ? cells : p
	char* else_arm = flag ? p : cells
	char* null_arm = flag ? cells : 0
	int data_word = cast(int, cells)
	return cast(int, then_arm) + cast(int, else_arm) +
			cast(int, null_arm) + data_word


# The bit-31 literal warning stays quiet for cast() bit patterns, for
# literals below bit 31 and for short binary literals; the 32-bit
# literal width error (grammar/int_literal.w) stays quiet for leading
# zeros — only significant digits count, so a 16-digit hex literal and
# a 40-digit binary literal whose value fits in 32 bits still compile;
# the bool-bitwise condition hint stays quiet for bool arithmetic
# outside conditions (call-free or not) and for the short-circuiting
# spellings — the default hint now fires for any call-free bool/
# comparison join inside a condition (see
# tests/bool_bitwise_warning_fixture.w for the positive cases and
# tests/bool_ops_warn_fixture.w for the call-containing joins that stay
# silent without --bool-ops).
int bit31_and_bool_bitwise_are_clean(int x):
	int mask = cast(int, 0xffffffff)
	int low = 0x7fffffff
	int bits = 0b101
	int wide_zeros = cast(int, 0x00000000ffffffff)
	int wide_bits = cast(int, 0b0000000011111111111111111111111111111111)
	bool first = x == 1
	bool second = x == 2
	# Outside a condition: accumulating comparison/bool results with '|'
	# is not a guard and stays silent regardless of call-freedom
	bool accumulated = first | second
	if ((x == 1) || (x == 2)):
		return mask & x
	if (wide_zeros == wide_bits):
		return low
	if (first || (x == 3)):
		return low
	if (first || second):
		return bits
	return cast(int, accumulated)


# A call's own '(' opens on the callee's line here, so its argument
# list is free to continue across following lines without tripping the
# cross-line call-tail warning (grammar/postfix_expr.w only checks the
# newline immediately before the '(' that opens the call, not anything
# inside an already-open argument list).
int multiline_call_args_are_clean(int x, int y):
	int total = add(x,
		y)
	return total


int main():
	int x = add(1, 2)
	x = add(x, 4)
	char* s = first_string(c"hello")
	s = first_string(s)
	if (x < s[0]):
		x = s[0]
	pair* p = new pair()
	p.a = 1
	p.b = 2
	x = x + pair_sum(p)
	if (cast_escape_hatches() == 0):
		x = 0
	if (array_decay_is_clean(x) == 0):
		x = 0
	if (bit31_and_bool_bitwise_are_clean(x) == 0):
		x = 0
	if (multiline_call_args_are_clean(x, 4) == 0):
		x = 0
	return x
