# The exact absorption documented in ai_tooling_next_steps.md and hit
# while shaping the #103 rejection fixtures (2026-07-16): 'int b = 2'
# followed by a line starting with '(' merges into that statement's own
# call tail instead of starting the intended '(a + b)++' statement, so
# this parses as the call '2(a + b)' with a postfix '++' left dangling
# in expression position. Before the cross-line-call warning existed,
# the only diagnostic was the generic '++' expression-position error
# below, with nothing pointing at the real mistake — a missing
# statement separation, not a bad '++' operand. Now the new warning
# fires first and names the actual cause; the downstream error is
# unchanged (the parse itself is still the same non-breaking absorption
# as tests/increment_non_lvalue_error_fixture.w's header describes).
# expect_fail
# expect_stderr: warning: call arguments continue from the previous line
# expect_stderr: '++' is a statement and cannot be used inside an expression
import lib.lib


int main():
	int a = 1
	int b = 2
	(a + b)++
	return 0
