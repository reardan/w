# expect_fail
# expect_stderr: operator '==' cannot be overloaded
# Only the binary arithmetic operators + - * / % are overloadable in
# v1; comparisons and every other spelling after 'operator' are
# rejected (docs/projects/operator_overloading.md).


struct optok_pt:
	int x
	int y


int operator==(optok_pt a, optok_pt b):
	return a.x == b.x


int main():
	return 0
