# 'portable' names the W body and cannot be redefined.
# expect_fail
# expect_stderr: asm label 'portable' is reserved for the portable W body
int f():
	asm x86:
		"portable:"
		"ret"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
