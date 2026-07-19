# Bitwise '|' / '&' joining two call-free bool/comparison operands
# inside an if or while condition reads as a logical guard but does not
# short-circuit (grammar/bitwise_or_expr.w, grammar/bitwise_and_expr.w);
# the warning_test target runs this fixture via bin/wfixture. The hint
# fires by default whenever both operands are call-free — bool-typed
# lvalues (ready/done below) and comparison results (the third case)
# alike; call-containing joins stay silent without --bool-ops (see
# tests/bool_ops_warn_fixture.w), and bool arithmetic outside a
# condition always stays silent (see tests/warning_clean_fixture.w).
# expect_stderr: warning: bitwise '|' on bool operands in a condition does not short-circuit; did you mean '||'?
# expect_stderr: warning: bitwise '&' on bool operands in a condition does not short-circuit; did you mean '&&'?
import lib.lib


int main():
	bool ready = true
	bool done = false
	int x = 1
	int y = 2
	if (ready | done):
		return 1
	while (ready & done):
		return 2
	# Comparison-result operands: silent under the pre-2026-07-17 default
	# (opt-in --bool-ops only), on by default now that the wave-2
	# mechanical sweep converted every side-effect-free site tree-wide.
	if ((x == 1) | (y == 2)):
		return 3
	return 0
