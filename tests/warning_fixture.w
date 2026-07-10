# Every construct below compiles but triggers exactly one warning.
# The warning_test build target compiles this file with bin/wfixture,
# which asserts each expected message below appears on stderr. The file
# also intentionally ends without a trailing newline to trigger the
# end-of-file warning.
# expect_stderr: warning: assignment type mismatch: expected 'char*', got 'int*'
# expect_stderr: warning: assignment type mismatch: expected 'char*', got 'char**'
# expect_stderr: warning: initialization type mismatch: expected 'int*', got 'char*'
# expect_stderr: warning: function 'takes_char_ptr' argument 1 type mismatch: expected 'char*', got 'int*'
# expect_stderr: warning: return type mismatch: expected 'char*', got 'int*'
# expect_stderr: warning: assignment type mismatch: expected 'pair', got 'single'
# expect_stderr: warning: assignment type mismatch: expected 'char*', got 'int'
# expect_stderr: warning: assignment type mismatch: expected 'int', got 'char*'
# expect_stderr: warning: function 'takes_char_ptr' argument 1 type mismatch: expected 'char*', got 'int'
# expect_stderr: warning: return type mismatch: expected 'char*', got 'int'
# expect_stderr: warning: initialization type mismatch: expected 'char*', got 'function'
# expect_stderr: warning: assignment type mismatch: expected 'int', got 'function'
# expect_stderr: warning: line indented with spaces instead of tabs
# expect_stderr: warning: file does not end with a newline
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


void int_to_pointer_assignment():
	int word = 5
	char* cp = "x"
	cp = word


void pointer_to_int_assignment():
	int word = 5
	char* cp = "x"
	word = cp


void int_to_pointer_argument():
	int word = 5
	takes_char_ptr(word)


char* int_to_pointer_return():
	int word = 5
	return word


void function_to_pointer_initialization():
	char* cp = takes_char_ptr


void function_to_int_assignment():
	int word = 5
	word = takes_char_ptr


# The single leading space below triggers the space-indentation warning
 int space_indented_global


int main():
	return 0

int no_trailing_newline_after_this