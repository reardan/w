# expect_fail
# expect_stderr: fixed array fields are not implemented in unions
union bad_union:
	int[2] values
	int fallback


int main(int argc, int argv):
	return 0
# wbuild: fixture_group=array_error_test
