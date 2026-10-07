# b.<cond> takes an A64 condition code.
# wfixture: arm64
# expect_fail
# expect_stderr: unknown arm64 branch condition in 'b.zz again'
int f():
	asm arm64:
		"again:"
		"b.zz again"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
