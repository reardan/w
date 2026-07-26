# Safer ':=' (issue #360): the diagnostic for a bare-function-name
# initializer names the variable being declared.
# expect_fail
# expect_stderr: cannot infer a type for 'g' from a bare function name
int ifn_helper():
	return 1

int main():
	g := ifn_helper
	return 0
