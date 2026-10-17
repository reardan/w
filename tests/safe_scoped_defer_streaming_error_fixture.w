# expect_fail
# wfixture: --streaming
# expect_stderr: scoped defer requires retained statement emission
int main():
	defer: 1
	return 0
