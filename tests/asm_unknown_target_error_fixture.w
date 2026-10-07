# An asm block names one of the supported ISAs.
# expect_fail
# expect_stderr: unknown asm target 'sparc' (expected x86, x64 or arm64)
int f():
	asm sparc:
		"ret"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
