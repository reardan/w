import lib.lib

struct ast_get_record:
	int number
	int16 small

int ast_get_order
int ast_get_arg(int n):
	ast_get_order = ast_get_order * 10 + n
	return n

map[int, int] ast_get_receiver(map[int, int] values):
	ast_get_order = ast_get_order * 10 + 1
	return values

int ast_get_sum(ast_get_record value): return value.number + value.small

int main():
	map[int, int] values = new map[int, int]
	values[2] = 21
	if (values.get(2) != 21): return 1
	if (values.get(99, 37) != 37): return 2
	if (ast_get_receiver(values).get(ast_get_arg(2), ast_get_arg(3)) != 21): return 3
	if (ast_get_order != 123): return 4
	map[int, map[int, int]] nested = new map[int, map[int, int]]
	nested[1] = values
	if (nested.get(1).get(2, 0) != 21): return 5
	map[string, string] words = new map[string, string]
	words[c"key"] = c"value"
	if (words.get(c"key", c"missing") != s"value"): return 6
	if (words.get(c"absent", c"missing") != s"missing"): return 7
	map[int, float32] reals = new map[int, float32]
	if (reals.get(99, 2.5) != 2.5): return 8
	map[int, int16] small = new map[int, int16]
	small[1] = -120
	if (small.get(1, -1) != -120): return 9
	map[int, ast_get_record] records = new map[int, ast_get_record]
	records[1] = ast_get_record(20, 3)
	ast_get_record absent = ast_get_record(8, 2)
	ast_get_record actual = records.get(1, absent)
	if (actual.number != 20 || actual.small != 3): return 10
	ast_get_record missing = records.get(99, ast_get_record(7, 4))
	if (missing.number != 7 || missing.small != 4): return 11
	if (ast_get_sum(records.get(1)) != 23): return 12
	return 0
