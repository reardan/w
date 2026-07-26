# Safer ':=' (issue #360): the diagnostic for a void initializer names
# the variable being declared.
# expect_fail
# expect_stderr: cannot infer a type for 'v' from a void expression
void ive_nothing():
	pass

int main():
	v := ive_nothing()
	return 0
