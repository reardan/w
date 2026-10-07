# Each line of an asm block is a string literal.
# expect_fail
# expect_stderr: asm block lines must be string literals, found 'ret'
int f():
	asm x86:
		ret
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
