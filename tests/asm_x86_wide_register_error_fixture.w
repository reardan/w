# r8d-r15d exist only on x64.
# expect_fail
# expect_stderr: unknown register or asm label in 'mov r8d,eax'
int f():
	asm x86:
		"mov r8d,eax"
		"ret"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
