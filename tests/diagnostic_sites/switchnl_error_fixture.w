# expect_fail
# expect_stderr: switch body must start on a new line
int main():
	int x = 1
	switch (x): case 1: return 1
	return 0
# wbuild: fixture_group=diagnostic_sites_test
