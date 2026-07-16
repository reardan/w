# '++'/'--' are statement-only in v1 (issue #103,
# docs/projects/increment_decrement.md): the prefix form inside a
# larger expression is rejected. This is also the diagnostic behind
# the pre-#103 double-unary reading of '--x', which lexes as one
# token now ('- -x' still stacks two unary minuses).
# expect_fail
# expect_stderr: '--' is a statement and cannot be used inside an expression
int main():
	int x = 5
	int y = --x
	return y
