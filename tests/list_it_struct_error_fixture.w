# The collected values travel as words: a struct-valued it-expression
# is rejected (map to a field or keep the element pointer 'it').
# wbuild: fixture_group=list_it_error_test
# expect_fail
# expect_stderr: list map expression must be a scalar value, got 'lise_point'
struct lise_point:
	int x

int main():
	list[lise_point] l = new list[lise_point]
	println(l.map(*it).length)
	return 0
