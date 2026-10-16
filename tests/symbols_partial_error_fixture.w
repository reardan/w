# 'w symbols --all-errors' fixture (tests/symbols_partial_error_fixture.w.wbuild):
# declarations on both sides of a statement that does not compile.
int sym_partial_before(int value):
	return value + 1


int sym_partial_broken():
	return sym_partial_missing(2)


int sym_partial_after(int value):
	return value * 2


int main():
	return sym_partial_before(1) + sym_partial_after(2)
