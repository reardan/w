# expect_fail
# expect_stderr: operator definition takes 2 parameters
# Overloadable operators are binary in v1 (prefix '-' is staged
# separately, docs/projects/operator_overloading.md), so a
# one-parameter definition is rejected.


struct opar_pt:
	int x
	int y


opar_pt operator+(opar_pt a):
	return a


int main():
	return 0
