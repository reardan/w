# A statement starting with '(' is absorbed as a call tail of the
# previous expression statement when the '(' sits on a different line
# (grammar/postfix_expr.w's postfix loop has no statement-boundary
# check of its own; a newline never ends an expression by itself here,
# same as everywhere else in W). The absorption still warns; calling
# the resulting integer is now a type error (#532), so this fixture
# fails compilation. See
# docs/projects/ai_tooling_next_steps.md.
# expect_fail
# expect_stderr: error: called object of type 'constant' is not a function
# expect_stderr: warning: call arguments continue from the previous line
import lib.lib


int cross_line_call_is_absorbed():
	int x = 2
	(x)
	return 0


int main():
	return cross_line_call_is_absorbed()
# wbuild: fixture_group=warning_test
