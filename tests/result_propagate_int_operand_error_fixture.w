import lib.result


# '?' on an operand that is not a wresult[...]* is not a propagation
# suffix: the token starts a ternary conditional, so a bare 'x?' with
# no arms is a syntax error.
wresult[int]* try_unwrap(int x):
	return result_new_ok[int](x?)
