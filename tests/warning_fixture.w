# Every construct below compiles but triggers exactly one warning.
# The warning_test Makefile target compiles this file and asserts each
# expected message appears on stderr. The file also intentionally ends
# without a trailing newline to trigger the end-of-file warning.
import lib.lib


struct pair:
	int a
	int b


struct single:
	int only


char* takes_char_ptr(char* s):
	return s


void assignment_base_mismatch():
	char* cp = c"x"
	int* ip = malloc(4)
	cp = ip


void assignment_level_mismatch():
	char* cp = c"x"
	char** cpp = &cp
	cp = cpp


void initialization_mismatch():
	char* cp = c"x"
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


# The single leading space below triggers the space-indentation warning
 int space_indented_global


int main():
	return 0

int no_trailing_newline_after_this