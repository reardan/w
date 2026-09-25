# A plain "..." (or f"...") literal where char* is expected decays to its
# NUL-terminated data pointer, silently, in every position (return,
# initialization, argument, assignment). An explicit s"..." literal stays
# a string and still warns; the warning_test target runs this fixture.
# reject_stderr: return type mismatch
# reject_stderr: argument 1 type mismatch
# reject_stderr: assignment type mismatch
# expect_stderr: warning: initialization type mismatch: expected 'char*', got 'string value'
void takes_char_ptr(char* s):
	pass


char* returns_char_ptr():
	return "plain return"


int main(int argc, int argv):
	char* p = "plain init"
	takes_char_ptr("plain arg")
	p = "plain assign"
	int n = 3
	p = f"formatted {n}"
	char* q = s"explicit string"
	return 0
