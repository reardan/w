struct ast_list_slice_record:
	int x
	int y

int ast_list_slice_sequence

int ast_list_slice_bound(int value):
	ast_list_slice_sequence = ast_list_slice_sequence * 10 + value
	return value

int main():
	list[int] original = list[int]{10, 11, 12, 13, 14}
	list[int] middle = original[1:4]
	list[int] tail = original[2:]
	list[int] head = original[:2]
	list[int] all = original[:]
	if (middle.length != 3 || middle[0] != 11 || middle[2] != 13): return 1
	if (tail.length != 3 || head.length != 2 || all.length != 5): return 2
	middle[0] = 99
	if (original[1] != 11): return 3
	list[int] negative = original[-3:-1]
	if (negative.length != 2 || negative[0] != 12 || negative[1] != 13): return 4
	list[int] ordered = original[ast_list_slice_bound(1):ast_list_slice_bound(4)]
	if (ast_list_slice_sequence != 14 || ordered.length != 3): return 5
	list[int] empty = original[2:2]
	if (empty.length != 0): return 6
	list[ast_list_slice_record] records = list[ast_list_slice_record]{ast_list_slice_record(1, 2), ast_list_slice_record(3, 4)}
	list[ast_list_slice_record] copied = records[1:]
	if (copied[0].x != 3 || copied[0].y != 4): return 7
	copied[0].x = 88
	if (records[1].x != 3): return 8
	if ((original[:][1:3][0]) != 11): return 9
	original.free()
	middle.free()
	tail.free()
	head.free()
	all.free()
	negative.free()
	ordered.free()
	empty.free()
	records.free()
	copied.free()
	return 0
