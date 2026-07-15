# expect_fail
# expect_stderr: operator definitions do not support variadic parameters
# Operator functions must be ordinary functions
# (docs/projects/operator_overloading.md): the use-site emitter always
# pushes exactly two arguments, so a W-variadic definition is rejected
# at the declaration instead of packing garbage at every use.


struct ovar_pt:
	int x
	int y


ovar_pt operator+(ovar_pt a, int... rest):
	return a


int main():
	return 0
