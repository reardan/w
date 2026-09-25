# Named constructor arguments (golf ergonomics wave 5) do not mix with
# positional ones: the named form zeroes the fields it leaves out.
# wbuild: fixture_group=named_ctor_error_test
# expect_fail
# expect_stderr: cannot mix positional and named constructor arguments
struct ncm_point:
	int x
	int y

int main():
	ncm_point* p = new ncm_point(x: 1, 2)
	return p.x
