# expect_fail
# expect_stderr: return with a value in a void function
void f():
	return 3
int main():
	f()
	return 0
# wbuild: fixture_group=diagnostic_sites_test
