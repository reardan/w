# Issue #532: under --strict every unsafe-conversion warning fails the
# compile, including the two older ones (a call with the wrong number of
# arguments and an int stored into a pointer). --strict already counts
# every warning (compiler/compiler.w); this fixture freezes that the new
# checks (grammar/type_check.w) feed it.
# wfixture: --strict
# expect_fail
# expect_stderr: warning: function 'falls_off' can reach the end of its body without returning a value
# expect_stderr: warning: return with a value in a void function
# expect_stderr: warning: initialization narrows constant 300 to 'char' (stored as 44)
# expect_stderr: warning: initialization converts '5' to enum 'color' implicitly
# expect_stderr: warning: '==' and '!=' on struct values compare their addresses
# expect_stderr: warning: duplicate case value 1 in switch
# expect_stderr: warning: function 'two' expects 2 arguments, got 1
# expect_stderr: warning: initialization type mismatch: expected 'char*', got 'int'
# expect_stderr: error: 8 warning(s) treated as errors (--strict)
# wbuild: fixture_group=warning_test
import lib.lib


enum color:
	red


struct point:
	int x


int two(int a, int b):
	return a + b


int falls_off(int x):
	if (x): return 1


void void_returns_value():
	return 5


int main():
	char c = 300
	color k = 5
	point a
	point b
	int same = a == b
	switch same:
		case 1:
			pass
		case 1:
			pass
	two(1)
	int n = 4
	char* p = n
	return 0
