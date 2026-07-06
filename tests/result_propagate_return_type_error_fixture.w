import lib.result


# '?' inside a function that does not return a wresult[...]* must be
# rejected: the error path would return an incompatible value.
int unwrap(wresult[int]* r):
	return r?
