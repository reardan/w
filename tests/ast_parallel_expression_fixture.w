struct ast_parallel_record:
	int number
	int tag

int ast_parallel_trace
int ast_parallel_mark(int n):
	ast_parallel_trace = ast_parallel_trace * 10 + n
	return n

ast_parallel_record ast_parallel_make(int n):
	ast_parallel_record value
	value.number = n
	value.tag = 2
	return value

int main():
	int a = 1
	int b = 2
	int c = 3
	a, b, c = c, a, b
	if (a != 3 || b != 1 || c != 2): return 1
	a, a = 4, 5
	if (a != 5): return 2
	int[3] values
	values[0] = 10
	values[1] = 20
	values[2] = 30
	values[ast_parallel_mark(1)], values[ast_parallel_mark(2)] = ast_parallel_mark(3), ast_parallel_mark(4)
	if (ast_parallel_trace != 1234): return 3
	if (values[1] != 3 || values[2] != 4): return 4
	int index = 0
	values[index], index = index + 7, 2
	if (values[0] != 7 || index != 2): return 5
	int* pa = &a
	int* pb = &b
	*pa, *pb = *pb, *pa
	if (a != 1 || b != 5): return 6
	pa, pb = pb, pa
	if (*pa != 5 || *pb != 1): return 7
	int16 x = -123
	int16 y = 234
	x, y = y, x
	if (x != 234 || y != -123): return 8
	float32 first = 1.5
	float32 second = 2.5
	first, second = second, first
	if (first != 2.5 || second != 1.5): return 9
	string left = s"left"
	string right = s"right"
	left, right = right, left
	if (left != s"right" || right != s"left"): return 10
	ast_parallel_record record
	record.number = 11
	record.tag = 22
	record.number, record.tag = record.tag, record.number
	if (record.number != 22 || record.tag != 11): return 11
	a, b = ast_parallel_make(6).number, ast_parallel_make(7).number
	if (a != 6 || b != 7): return 12
	for i in range(3): a, b = b, a + b
	if (a != 20 || b != 33): return 13
	return 0
