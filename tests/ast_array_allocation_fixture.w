int ast_array_length_calls

int ast_array_length():
	ast_array_length_calls += 1
	return 4

struct ast_array_record:
	int x
	char tag

int main():
	int[] values = (new int[ast_array_length()])
	if (ast_array_length_calls != 1): return 1
	if (values.length != 4): return 2
	if (values[0] != 0 || values[3] != 0): return 3
	values[3] = 42
	if (values[3] != 42): return 4
	char[] chars = (new char[3])
	if (chars[0] != 0 || chars[2] != 0): return 5
	chars[1] = 'a'
	if (chars[1] != 'a'): return 6
	int[] empty = (new int[0])
	if (empty.length != 0): return 7
	ast_array_record[] records = (new ast_array_record[2])
	if (records[1].x != 0 || records[1].tag != 0): return 8
	records[1].x = 42
	if (records[1].x != 42): return 9
	if (((new int[2]).length) != 2): return 10
	return 0
