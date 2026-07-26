# Safer ':=' (issue #360): a parameter is already a visible binding, so
# 'a := ...' inside the function silently shadowing it was a bug trap.
# expect_fail
# expect_stderr: ':=' redeclares 'a'; use '=' to assign, or a typed declaration to shadow
int isp_double(int a):
	a := a + a
	return a

int main():
	return isp_double(2)
