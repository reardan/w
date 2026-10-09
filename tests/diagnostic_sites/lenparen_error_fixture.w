# expect_fail
# expect_stderr: ')' expected in len
int main():
	list[int] l = new list[int]
	int n = len(l, 3)
	return 0
# wbuild: fixture_group=diagnostic_sites_test
