# expect_fail
# expect_stderr: range iteration takes one loop variable
int main():
	for i, j in range(3):
		print(i)
	return 0
# wbuild: fixture_group=diagnostic_sites_test
