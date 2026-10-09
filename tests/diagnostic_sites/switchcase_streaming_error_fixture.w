# wfixture: --streaming
# expect_fail
# expect_stderr: 'case' or 'default' expected in switch body
int main():
	int x = 1
	switch (x):
		foo 1:
			return 1
	return 0
# wbuild: fixture_group=diagnostic_sites_test
