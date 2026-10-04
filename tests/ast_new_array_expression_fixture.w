struct ast_array_record:
	int16 small
	int large

int ast_array_count_calls

int ast_array_count():
	ast_array_count_calls += 1
	return 4

int ast_array_sum(int[] values):
	int result = 0
	for i in range(values.length): result += values[i]
	return result

int main():
	int[] values = new int[ast_array_count()]
	if (ast_array_count_calls != 1 || values.length != 4): return 1
	for i in range(4):
		if (values[i] != 0): return 2
		values[i] = i + 1
	if ((ast_array_sum(values)) != 10): return 3
	if ((ast_array_sum(new int[3])) != 0): return 4
	char[] bytes = new char[5]
	if (bytes.length != 5 || bytes[4] != 0): return 5
	bytes[2] = 'x'
	if (bytes[2] != 'x'): return 6
	ast_array_record[] records = new ast_array_record[2]
	if (records[1].small != 0 || records[1].large != 0): return 7
	records[1].large = 9
	if (records[1].large != 9): return 8
	int[] empty = new int[0]
	if (empty.length != 0): return 9
	int* data_ptr = cast(int*, new int[2])
	if (data_ptr[0] != 0 || data_ptr[1] != 0): return 10
	free(cast(char*, values.data) - 2 * __word_size__)
	free(cast(char*, bytes.data) - 2 * __word_size__)
	free(cast(char*, records.data) - 2 * __word_size__)
	free(cast(char*, empty.data) - 2 * __word_size__)
	free(cast(char*, data_ptr) - 2 * __word_size__)
	return 0
