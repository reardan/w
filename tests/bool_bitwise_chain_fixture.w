# A same-precedence chain of 3+ terms used to under-report: only the
# first '&'/'|' pairing was ever checked, because binary2_finish_pop
# (grammar/binary_op.w) returned an untyped placeholder that erased the
# fold's bool-ness before the next pairing's check ran. Each pairing's
# own bool/purity is now tracked alongside the running fold
# (chain_is_bool/chain_is_pure in grammar/bitwise_and_expr.w /
# bitwise_or_expr.w), so every qualifying pairing in the chain warns —
# both '&'s below, at their own operator position rather than wherever
# the tokenizer's lookahead lands once the whole condition finishes
# parsing. check_bool_ops_test's --json step asserts two diagnostics at
# two distinct columns on the same line, one per '&'.
# expect_stderr: warning: bitwise '&' on bool operands in a condition does not short-circuit; did you mean '&&'?
import lib.lib


int main():
	int a = 1
	int b = 2
	int c = 3
	if ((a == 1) & (b == 2) & (c == 3)):
		return 1
	return 0
