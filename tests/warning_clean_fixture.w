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
	return x
