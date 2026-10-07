# Labels are unique within a block.
# expect_fail
# expect_stderr: asm label 'again' is defined twice
int f():
	asm x86:
		"again:"
		"again: ret"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
