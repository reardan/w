# expect_fail
# expect_stderr: list map expects a function, got 'constant'
int dbl(int x):
	return x * 2
int main():
	list[int] l = new list[int]
	list[int] r = l.map(3)
	return 0
# wbuild: fixture_group=diagnostic_sites_test
