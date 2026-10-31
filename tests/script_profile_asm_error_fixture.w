# Assembly function bodies emit arbitrary machine code.
# wfixture: --profile=script
# expect_fail
# expect_stderr: script profile: asm blocks are not allowed
int answer():
	asm x86:
		"mov eax, 42"
		"ret"
	return 42


int main():
	return answer()
# wbuild: fixture_group=script_profile_error_test
