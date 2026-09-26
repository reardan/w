# A named constructor argument must name a field of the struct.
# wbuild: fixture_group=named_ctor_error_test
# expect_fail
# expect_stderr: struct field 'z' not found
struct ncf_point:
	int x
	int y

int main():
	ncf_point p = ncf_point(x: 1, z: 2)
	return p.x
