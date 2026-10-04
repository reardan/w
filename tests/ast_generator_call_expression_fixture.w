import lib.generator

int ast_generator_order

int ast_generator_mark(int n):
	ast_generator_order = ast_generator_order * 10 + n
	return n

generator int ast_generator_values(int first, int second = 3, bool enabled = true):
	if (enabled):
		yield first
		yield second

generator int ast_generator_empty():
	return

generator int ast_generator_float(float32 value):
	yield cast(int, value)

generator int ast_generator_nested(int value):
	generator* inner = ast_generator_values(value)
	while (gen_next(inner)): yield gen_value(inner) + 1
	gen_free(inner)

int ast_generator_sum(generator* values):
	int result = 0
	while (gen_next(values)): result = result + gen_value(values)
	gen_free(values)
	return result

int main():
	generator* values = ast_generator_values(ast_generator_mark(1), ast_generator_mark(2))
	if (ast_generator_order != 12): return 1
	if (ast_generator_sum(values) != 3): return 2
	if (ast_generator_sum(ast_generator_values(5)) != 8): return 3
	if (ast_generator_sum(ast_generator_values(5, 6, false)) != 0): return 4
	if (ast_generator_sum(ast_generator_empty()) != 0): return 5
	if (ast_generator_sum(ast_generator_float(7.5)) != 7): return 6
	if (ast_generator_sum(ast_generator_nested(4)) != 9): return 7
	return 0
