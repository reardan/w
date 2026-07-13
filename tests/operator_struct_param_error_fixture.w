# expect_fail
# expect_stderr: operator parameters require a struct type
# Overloads can never change the meaning of scalar arithmetic
# (docs/projects/operator_overloading.md): an operator definition whose
# parameters carry no struct-value type is rejected.


int operator+(int a, int b):
	return a + b


int main():
	return 0
