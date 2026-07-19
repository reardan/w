# A statement starting with '(' is absorbed as a call tail of the
# previous expression statement when the '(' sits on a different line
# (grammar/postfix_expr.w's postfix loop has no statement-boundary
# check of its own; a newline never ends an expression by itself here,
# same as everywhere else in W). This stays non-breaking — the call is
# still parsed and compiled exactly as before — but the absorption now
# warns so it isn't silently invisible; see
# docs/projects/ai_tooling_next_steps.md.
# expect_stderr: warning: call arguments continue from the previous line
import lib.lib


int cross_line_call_is_absorbed():
	int x = 2
	(x)
	return 0


int main():
	return cross_line_call_is_absorbed()
