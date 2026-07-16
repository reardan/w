# '++'/'--' are statement-only in v1 (issue #103,
# docs/projects/increment_decrement.md): the postfix form inside a
# larger expression has no value and is rejected.
# expect_fail
# expect_stderr: '++' is a statement and cannot be used inside an expression
int main():
	int x = 1
	int y = x++
	return y
