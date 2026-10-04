import lib.lib

struct ast_variadic_pair:
	int x
	int y

int ast_variadic_sum(int... values):
	int sum = 0
	for int i in range(values.length): sum = sum + values[i]
	return sum

int ast_variadic_pick(int index, int... values): return values[index]
int ast_variadic_fixed(int factor, int offset, int... values):
	for int i in range(values.length): offset = offset + factor * values[i]
	return offset

int ast_variadic_text(string... values):
	int length = 0
	for int i in range(values.length): length = length + values[i].length
	return length

int ast_variadic_cstr(char*... values):
	int length = 0
	for int i in range(values.length): length = length + strlen(values[i])
	return length

ast_variadic_pair ast_variadic_record(ast_variadic_pair pair, int... values):
	for int i in range(values.length): pair.x = pair.x + values[i]
	return pair

type ast_variadic_callback = fn(int) -> int
int ast_variadic_increment(int value): return value + 1
int ast_variadic_apply(int value, ast_variadic_callback*... callbacks):
	for int i in range(callbacks.length): value = callbacks[i](value)
	return value

int ast_variadic_order
int ast_variadic_mark(int value):
	ast_variadic_order = ast_variadic_order * 10 + value
	return value

int main():
	if (ast_variadic_sum() != 0): return 1
	if (ast_variadic_sum(7) != 7): return 2
	if (ast_variadic_sum(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) != 78): return 3
	if (ast_variadic_pick(1, 7, 8, 9) != 8): return 4
	if (ast_variadic_fixed(2, 10) != 10): return 5
	if (ast_variadic_fixed(2, 10, 3, 4) != 24): return 6
	if (ast_variadic_sum(ast_variadic_sum(1, 2), ast_variadic_sum(3, 4)) != 10): return 7
	if (ast_variadic_fixed(ast_variadic_mark(1), ast_variadic_mark(2), ast_variadic_mark(3), ast_variadic_mark(4)) != 9): return 8
	if (ast_variadic_order != 1234): return 9
	if (ast_variadic_sum(1, 2.5, 3) != 6): return 10
	if (ast_variadic_text(s"ab", c"cde") != 5): return 11
	char[3] text
	text[0] = 'h'
	text[1] = 'i'
	text[2] = 0
	if (ast_variadic_cstr(text, c"!") != 3): return 12
	ast_variadic_pair pair = ast_variadic_record(ast_variadic_pair(2, 3), 4, 5)
	if (pair.x != 11 || pair.y != 3): return 13
	if (ast_variadic_record(ast_variadic_record(pair, 1), 2).x != 14): return 14
	if (ast_variadic_record(pair).y != 3): return 15
	if (ast_variadic_apply(4, ast_variadic_increment, ast_variadic_increment) != 6): return 16
	return 0
