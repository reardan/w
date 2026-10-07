# One block per ISA.
# expect_fail
# expect_stderr: duplicate asm block for 'x86'
int f():
	asm x86:
		"ret"
	asm x86:
		"ret"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
