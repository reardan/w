# A branch target must be a label defined in the block.
# expect_fail
# expect_stderr: undefined asm label in 'jmp nowhere'
int f():
	asm x86:
		"jmp nowhere"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
