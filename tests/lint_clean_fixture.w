# 'w check --lint' must stay silent on every construct below: each one
# sits next to a lint rule (compiler/lint.w) without breaking it.
import lib.lib


int next_value(int a):
	return a - 1


int loops(int n):
	int total = 0
	# Unused loop variables, and sibling loops reusing a name
	for int i in range(n):
		total = total + 1
	for int i in range(n):
		total = total + i
	for j in range(n):
		total = total + 2
	return total


int intentional(int a):
	# '_'-prefixed locals and 'nolint' lines opt out
	int _spare = a
	int kept = a # nolint
	# Extra parentheses mark a deliberate assignment in a condition, and
	# an assignment inside a comparison is not the whole condition
	if ((a = next_value(a))):
		a = a + 1
	while ((a = next_value(a)) > 0):
		pass
	return a


int labels(int a):
	# Code after a goto is reachable again from the label
	goto done
	done:
	return a


int scopes(int a):
	# Sibling blocks may reuse a name: the first one is out of scope
	if (a > 0):
		int b = a
		a = b
	else:
		int b = 0 - a
		a = b
	int copy = a
	a = copy + 0
	return a


int main():
	return loops(2) + intentional(3) + labels(4) + scopes(5)
