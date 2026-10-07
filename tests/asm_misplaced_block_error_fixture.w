# Asm blocks open the function body; they are not statements.
# expect_fail
# expect_stderr: an asm block must open a function body, before its first statement
int f():
	int x = 1
	asm x86:
		"ret"
	return x


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
