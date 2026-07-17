# '++'/'--' reuse the compound-assignment assignability checks
# (grammar/increment.w): a non-lvalue operand — here a bare constant —
# fails the same way '5 += 1' would. (A '(a + b)++' spelling would not
# reach this check: a line starting with '(' is absorbed as a call of
# the previous expression statement, W's long-standing postfix-call
# parse across newlines.)
# expect_fail
# expect_stderr: assignment target is not assignable
int main():
	5++
	return 0
