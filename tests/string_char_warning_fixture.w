# Passing "string value" literals where char* is expected triggers one
# warning per position; the warning_test target runs this fixture.
# expect_stderr: warning: return type mismatch: expected 'char*', got 'string value'
# expect_stderr: warning: initialization type mismatch: expected 'char*', got 'string value'
# expect_stderr: warning: function 'takes_char_ptr' argument 1 type mismatch: expected 'char*', got 'string value'
# expect_stderr: warning: assignment type mismatch: expected 'char*', got 'string value'
void takes_char_ptr(char* s):
	pass


char* returns_char_ptr():
	return "plain return"


int main(int argc, int argv):
	char* p = "plain init"
	takes_char_ptr("plain arg")
	p = "plain assign"
	return 0
