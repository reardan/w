# Uniform call syntax passes a struct receiver by address, so a free
# function taking the struct BY VALUE is not a candidate: the method
# diagnostic stays.
# wbuild: fixture_group=ufcs_error_test
# expect_fail
# expect_stderr: struct method 'ufe_point.norm' not found; expected function 'ufe_point_norm'
struct ufe_point:
	int x

int norm(ufe_point p):
	return p.x

int main():
	ufe_point p
	p.x = 1
	return p.norm()
