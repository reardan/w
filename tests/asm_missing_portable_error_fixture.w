# Every asm function keeps a portable W body for the other targets.
# expect_fail
# expect_stderr: function 'f' needs a portable W body after its asm blocks
int f():
	asm x86:
		"mov eax,1"
		"ret"


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
