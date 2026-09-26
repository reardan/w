# expect_fail
# expect_stderr: duplicate label 'twice'
int main(int argc, int argv):
	twice:
	twice:
	return 0
# wbuild: fixture_group=goto_error_test
