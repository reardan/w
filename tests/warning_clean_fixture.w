# Cleanly typed program: the warning_test Makefile target asserts that
# compiling this file produces no warnings on stderr.
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


int main():
	int x = add(1, 2)
	x = add(x, 4)
	char* s = first_string("hello")
	s = first_string(s)
	if (x < s[0]):
		x = s[0]
	pair* p = new pair()
	p.a = 1
	p.b = 2
	x = x + pair_sum(p)
	return x
