struct ast_buffer_first:
	int value

struct ast_buffer_later:
	int value

struct ast_buffer_unseen:
	int value

struct ast_buffer_final:
	int value

int ast_buffer_sum(int* values, int n):
	int total = 0
	for i in range(n): total += values[i]
	return total

int ast_buffer_slice_sum(int[] values):
	return ast_buffer_sum(values, values.length)

int ast_buffer_mixed(ast_buffer_first* values, ast_buffer_later* other):
	return values[0].value + (other != 0)

int ast_buffer_present(void* first, void* second): return (first != 0) + (second != 0)

int[] ast_buffer_return(int[] values): return values

type ast_buffer_callback = fn(int*, int) -> int

int main():
	int[3] values
	values[0] = 4
	values[1] = 5
	values[2] = 6
	if ((ast_buffer_sum(values, 3)) != 15): return 1
	if ((ast_buffer_slice_sum(values)) != 15): return 2
	int[] slice = values
	int* pointer = values
	if ((ast_buffer_sum(slice, 3)) != 15): return 3
	if (pointer[1] != 5): return 4
	int[] copied = ast_buffer_return(slice)
	if (copied[2] != 6): return 5
	if 1: (slice = values)
	if 1: (pointer = slice)
	if (pointer[0] != 4): return 6
	ast_buffer_callback* callback = ast_buffer_sum
	if ((callback(values, 3)) != 15): return 7
	int raw = cast(int, ast_buffer_slice_sum)
	if ((raw(values)) != 15): return 8
	ast_buffer_first[1] records
	records[0].value = 8
	if ((ast_buffer_mixed(records, cast(ast_buffer_later*, 0))) != 8): return 9
	ast_buffer_unseen[1] unseen
	if ((ast_buffer_present(unseen, cast(ast_buffer_final*, 0))) != 1): return 10
	return 0
