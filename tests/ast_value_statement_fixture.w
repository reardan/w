import lib.generator

int ast_value_trace

void ast_value_mark(int n):
	ast_value_trace = ast_value_trace * 10 + n

struct ast_return_pair:
	int first
	int second

ast_return_pair ast_make_pair():
	defer ast_value_mark(1)
	return ast_return_pair(20, 22)

void ast_bare_return():
	defer ast_value_mark(2)
	return

generator int ast_yield_values():
	for i in range(5):
		if (i == 2): return
		yield i + 10

int main():
	ast_return_pair pair = ast_make_pair()
	if (pair.first + pair.second != 42): return 1
	ast_bare_return()
	if (ast_value_trace != 12): return 2
	int sum = 0
	for int value in ast_yield_values(): sum = sum + value
	if (sum != 21): return 3
	return 0
