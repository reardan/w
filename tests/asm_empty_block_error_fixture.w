# An asm block holds at least one indented line.
# expect_fail
# expect_stderr: an asm block's lines must be indented string literals
int f():
	asm x86:
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
