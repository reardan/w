struct ast_method_record:
	int x
	int y

int ast_method_order

list[int] ast_method_receiver(list[int] values):
	ast_method_order = ast_method_order * 10 + 1
	return values

int ast_method_argument():
	ast_method_order = ast_method_order * 10 + 2
	return 3

int ast_method_outer_it(list[int] values):
	int it = 3
	return values.count(it)

int ast_method_unused_it(list[int] values):
	int it = 99
	return values.sum()

int main():
	list[int] values = list[int]{3, -1, 3, 2}
	if (values.sum() != 7 || values.min() != -1 || values.max() != 3): return 1
	if (values.count(3) != 2 || values.index(3) != 0 || values.index(9) != -1): return 2
	if (ast_method_receiver(values).count(ast_method_argument()) != 2): return 3
	if (ast_method_order != 12): return 4
	if (ast_method_outer_it(values) != 2 || ast_method_unused_it(values) != 7): return 5
	list[int] ordered = values.sorted()
	if (ordered[0] != -1 || ordered[3] != 3 || values[0] != 3): return 6
	values.sort()
	if (values[0] != -1 || values[1] != 2): return 7
	list[int] backwards = values.reversed()
	if (backwards[0] != 3 || backwards[3] != -1 || values[0] != -1): return 8
	values.reverse()
	if (values[0] != 3 || values[3] != -1): return 9
	list[int16] small = list[int16]{-20, 7, 2}
	if (small.sum() != -11 || small.min() != -20 || small.max() != 7): return 10
	list[char*] words = list[char*]{c"zebra", c"apple", c"zebra"}
	if (words.count(c"zebra") != 2 || words.index(c"apple") != 1): return 11
	words.sort()
	if (words[0][0] != 'a'): return 12
	list[ast_method_record] records = list[ast_method_record]{ast_method_record(1, 2), ast_method_record(3, 4)}
	list[ast_method_record] copies = records.reversed()
	if (copies[0].x != 3 || copies[1].y != 2): return 13
	copies[0].x = 88
	if (records[1].x != 3): return 14
	records.reverse()
	if (records[0].x != 3 || records[1].y != 2): return 15
	list[float32] reals = list[float32]{1.5, 2.5}
	reals.reverse()
	if (reals[0] != 2.5): return 16
	values.free()
	ordered.free()
	backwards.free()
	small.free()
	words.free()
	records.free()
	copies.free()
	reals.free()
	return 0
