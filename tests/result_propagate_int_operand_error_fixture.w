import lib.result


# '?' on an operand that is not a wresult[...]* must be rejected.
wresult[int]* try_unwrap(int x):
	return result_new_ok[int](x?)
