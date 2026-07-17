# Bitwise '|' / '&' joining two bool-typed lvalues inside an if or
# while condition reads as a logical guard but does not short-circuit
# (grammar/bitwise_or_expr.w, grammar/bitwise_and_expr.w); the
# warning_test target runs this fixture via bin/wfixture. Comparison
# results and bool arithmetic outside conditions stay silent — those
# negative cases live in tests/warning_clean_fixture.w.
# expect_stderr: warning: bitwise '|' on bool operands in a condition does not short-circuit; did you mean '||'?
# expect_stderr: warning: bitwise '&' on bool operands in a condition does not short-circuit; did you mean '&&'?
import lib.lib


int main():
	bool ready = true
	bool done = false
	if (ready | done):
		return 1
	while (ready & done):
		return 2
	return 0
