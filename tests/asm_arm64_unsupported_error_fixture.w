# Forms the A64 text assembler cannot encode are rejected, not emitted as zero words.
# wfixture: arm64
# expect_fail
# expect_stderr: cannot assemble arm64 instruction 'ror x0,x0,#3'
int f():
	asm arm64:
		"ror x0,x0,#3"
		"ret"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
