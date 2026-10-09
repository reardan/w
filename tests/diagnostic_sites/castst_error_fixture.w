# expect_fail
# expect_stderr: cannot cast to a struct value
struct P:
	int a
	int b
int main():
	P p = cast(P, 3)
	return 0
# wbuild: fixture_group=diagnostic_sites_test
