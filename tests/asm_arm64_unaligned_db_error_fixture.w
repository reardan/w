# A64 instructions stay 4-byte aligned after raw db bytes.
# wfixture: arm64
# expect_fail
# expect_stderr: arm64 instruction 'ret' is not 4-byte aligned (pad the db bytes before it)
int f():
	asm arm64:
		"db 0x00"
		"ret"
	return 0


int main():
	return f()
# wbuild: fixture_group=asm_function_error_test
