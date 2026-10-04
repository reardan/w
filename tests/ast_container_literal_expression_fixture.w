struct ast_literal_record:
	int x
	int y

int ast_literal_sequence

int ast_literal_tick(int value):
	ast_literal_sequence = ast_literal_sequence * 10 + value
	return value

ast_literal_record ast_literal_make(int value):
	ast_literal_record result
	result.x = value
	result.y = value + 1
	return result

int main():
	list[int] numbers = list[int]{1, 2, 3,}
	if (numbers.length != 3 || numbers[1] != 2): return 1
	list[int] empty = list[int]{}
	if (empty.length != 0): return 2
	map[int, int] mapping = map[int, int]{ast_literal_tick(1): ast_literal_tick(2), ast_literal_tick(3): ast_literal_tick(4)}
	if (ast_literal_sequence != 1234 || mapping[1] != 2 || mapping[3] != 4): return 3
	set[char*] names = set[char*]{"one", c"two", "one",}
	if (names.length != 2 || (c"two" in names) == 0): return 4
	list[list[int]] nested = list[list[int]]{list[int]{5, 6}, list[int]{7}}
	if (nested[0][1] != 6 || nested[1][0] != 7): return 5
	list[ast_literal_record] records = list[ast_literal_record]{ast_literal_make(8), ast_literal_make(10)}
	if (records[0].x != 8 || records[1].y != 11): return 6
	map[int, ast_literal_record] objects = map[int, ast_literal_record]{1: ast_literal_make(12), 2: ast_literal_make(14),}
	if (objects[1].y != 13 || objects[2].x != 14): return 7
	list[int] multiline = list[int]{
		1,
		# literal braces do not end the expression
		2,
		3,
	}
	if (multiline[2] != 3): return 8
	if ((list[int]{4, 5}.length) != 2): return 9
	if ((map[int, int]{2: 9}[2]) != 9): return 10
	numbers.free()
	empty.free()
	mapping.free()
	names.free()
	nested[0].free()
	nested[1].free()
	nested.free()
	records.free()
	objects.free()
	multiline.free()
	return 0
