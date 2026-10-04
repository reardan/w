import lib.result

int ast_propagate_order
void ast_propagate_mark(int n): ast_propagate_order = ast_propagate_order * 10 + n

wresult[int]* ast_propagate_source(int n):
	if (n < 0): return result_new_error[int](n)
	return result_new_ok[int](n)

wresult[int]* ast_propagate_deferred(int n):
	defer ast_propagate_mark(9)
	int value = ast_propagate_source(n)?
	ast_propagate_mark(1)
	return result_new_ok[int](value + 1)

wresult[int]* ast_propagate_condition(int n):
	if ast_propagate_source(n)?: return result_new_ok[int](7)
	return result_new_ok[int](3)

wresult[int]* ast_propagate_ternary(int n):
	return result_new_ok[int](ast_propagate_source(n)? ? 10 : 20)

wresult[int]* ast_propagate_store():
	wresult[int]* r = ast_propagate_source(1)
	r? = 8
	return r

int main():
	wresult[int]* r = ast_propagate_deferred(4)
	if (r.value != 5 || ast_propagate_order != 19): return 1
	ast_propagate_order = 0
	r = ast_propagate_deferred(-7)
	if (r.ok != 0 || r.code != -7 || ast_propagate_order != 9): return 2
	r = ast_propagate_condition(1)
	if (r.value != 7): return 3
	r = ast_propagate_condition(0)
	if (r.value != 3): return 4
	r = ast_propagate_condition(-3)
	if (r.code != -3): return 5
	r = ast_propagate_ternary(0)
	if (r.value != 20): return 6
	r = ast_propagate_store()
	if (r.value != 8): return 7
	return 0
