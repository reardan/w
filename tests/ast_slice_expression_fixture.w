int ast_slice_sequence

int ast_slice_bound(int value):
	ast_slice_sequence = ast_slice_sequence * 10 + value
	return value

int ast_slice_sum(int[] values):
	int total = 0
	for i in range(values.length): total += values[i]
	return total

int main():
	int[5] values
	for i in range(5): values[i] = i + 10
	int[] middle = values[1:4]
	if (middle.length != 3 || middle[0] != 11 || middle[2] != 13): return 1
	int[] tail = values[2:]
	int[] head = values[:2]
	int[] all = values[:]
	if (tail.length != 3 || head.length != 2 || all.length != 5): return 2
	if ((ast_slice_sum(values[1:3])) != 23): return 3
	if ((values[1:][1:3][0]) != 12): return 4
	int[] ordered = values[ast_slice_bound(1):ast_slice_bound(4)]
	if (ast_slice_sequence != 14 || ordered[0] != 11): return 5
	int[] empty = values[2:2]
	if (empty.length != 0): return 6
	middle[0] = 21
	if (values[1] != 21): return 7
	int* data_ptr = cast(int*, values)
	if (data_ptr[1] != 21): return 8
	data_ptr = cast(int*, values[2:4])
	if (data_ptr[0] != 12): return 9
	int address = cast(int, values)
	if (address != cast(int, values.data)): return 10
	void* raw = cast(void*, all)
	if (cast(int, raw) != address): return 11
	string text = "abcdef"
	string part = text[1:4]
	if (part.length != 3 || part[0] != 'b' || part[2] != 'd'): return 12
	if ((text[:2].length) != 2 || (text[4:][1]) != 'f'): return 13
	if ((text[:].length) != 6 || (text[3:3].length) != 0): return 14
	if (("hello"[1:4][0]) != 'e'): return 15
	return 0
