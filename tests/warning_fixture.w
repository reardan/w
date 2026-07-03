# Every construct below compiles but triggers exactly one type warning.
# The warning_test Makefile target compiles this file and asserts each
# expected message appears on stderr.
import lib.lib


struct pair:
	int a
	int b


struct single:
	int only


char* takes_char_ptr(char* s):
	return s


void assignment_base_mismatch():
	char* cp = "x"
	int* ip = malloc(4)
	cp = ip


void assignment_level_mismatch():
	char* cp = "x"
	char** cpp = &cp
	cp = cpp


void initialization_mismatch():
	char* cp = "x"
	int* ip = cp


void argument_mismatch():
	int* ip = malloc(4)
	takes_char_ptr(ip)


char* return_mismatch():
	int* ip = malloc(4)
	return ip


void struct_mismatch():
	pair p
	single s
	p.a = 1
	s.only = 2
	p = s


int main():
	return 0
