# expect_fail
# expect_stderr: right operand of 'in' must be a map, set, or list
int main():
	int x = 3
	if (1 in x): return 1
	return 0
# wbuild: fixture_group=diagnostic_sites_test
