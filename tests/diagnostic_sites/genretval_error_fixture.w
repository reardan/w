# expect_fail
# expect_stderr: generators cannot return a value; use yield
import lib.generator
generator int g():
	return 3
int main():
	return 0
# wbuild: fixture_group=diagnostic_sites_test
