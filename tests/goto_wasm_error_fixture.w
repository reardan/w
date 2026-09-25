# wfixture: wasm
# expect_fail
# expect_stderr: 'goto' and labels are only supported on native targets
int main(int argc, int argv):
	goto end
	end:
	return 0
# wbuild: fixture_group=goto_error_test
