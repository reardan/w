struct ast_composite_record:
	int x
	int y

int ast_composite_read[T](T[] values):
	return values[0]

int ast_composite_length[T](list[T] values):
	return values.length

int main():
	values := list[int16]{4, 8}
	if (values[0] + values[1] != 12): return 1
	keys := set[uint16]{2, 7}
	if (!(7 in keys)): return 2
	records := map[int16, ast_composite_record]{2: ast_composite_record(3, 9)}
	if (records[2].y != 9): return 3
	nested := list[list[uint8]]{list[uint8]{1, 2}, list[uint8]{3}}
	if (nested[0][1] != 2 || nested[1][0] != 3): return 4
	first := cast(list[uint32]*, 0)
	second := cast(list[uint32]*, 0)
	if (first != second): return 5
	if (sizeof(list[uint32]) != __word_size__): return 6
	if (sizeof(uint16[]) != __word_size__): return 7
	if (ast_composite_read[char](new char[2]) != 0): return 8
	if (ast_composite_length[ast_composite_record](list[ast_composite_record]{ast_composite_record(7, 8)}) != 1): return 9
	empty := new map[uint8, list[ast_composite_record]]
	if (empty.length != 0): return 10
	values.free()
	keys.free()
	records.free()
	nested[0].free()
	nested[1].free()
	nested.free()
	empty.free()
	return 0
