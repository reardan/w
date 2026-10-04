struct ast_decl_record:
	int tag
	int[3] values


ast_decl_record ast_decl_make(int value):
	ast_decl_record result
	result.tag = value
	result.values[0] = value + 1
	result.values[2] = value + 3
	return result


int main():
	int[3] array
	array[0] = 6
	array[2] = 7
	ast_decl_record original = ast_decl_make(array[0])
	ast_decl_record typed_copy = original
	inferred_copy := original
	typed_copy.values[0] = 90
	inferred_copy.values[2] = 80
	if (original.values[0] != 7 || original.values[2] != 9): return 1
	if (typed_copy.values[0] != 90 || typed_copy.values[2] != 9): return 2
	if (inferred_copy.values[0] != 7 || inferred_copy.values[2] != 80): return 3
	int16 small = -4
	float32 wide = 1.5
	uint32 integer = 27
	int value = 3
	if (true):
		int value = 8
		if (value != 8): return 4
	if (value != 3 || small != -4 || wide != 1.5 || integer != 27): return 5
	ptr := &value
	*ptr = 10
	if (value != 10 || array[2] != 7): return 6
	return 0
