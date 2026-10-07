# Lines go through the libs/asm text assembler.
# expect_fail
# expect_stderr: cannot assemble x86 instruction 'frobnicate eax'
int f():
	asm x86:
		"frobnicate eax"
		"ret"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
