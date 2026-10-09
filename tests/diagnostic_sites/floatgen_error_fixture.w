# expect_fail
# expect_stderr: float64 requires the x64 target
T id[T](T x):
	return x
int main():
	float64 d = 1.0
	return 0
# wbuild: fixture_group=diagnostic_sites_test
