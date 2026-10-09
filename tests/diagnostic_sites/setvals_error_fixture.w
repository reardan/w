# expect_fail
# expect_stderr: sets have no values: use one loop variable
int main():
	set[int] s = new set[int]
	for int k, int v in s:
		print(k)
	return 0
# wbuild: fixture_group=diagnostic_sites_test
