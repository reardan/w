# Ordinary expression statements own their prepared arena until emission.
# Exercise side effects, temporaries and the following statement boundary.
struct ast_statement_pair:
	int first
	int second

int ast_statement_trace

int ast_statement_mark(int n):
	ast_statement_trace = ast_statement_trace * 10 + n
	return n

void ast_statement_touch(int* value):
	*value = *value + 1

ast_statement_pair ast_statement_make(int n):
	ast_statement_pair value
	value.first = n
	value.second = n + 1
	return value

int main():
	int left = 1
	int right = 2
	left, right = right, left
	if (left != 2 || right != 1): return 1
	left++
	ast_statement_touch(&right)
	if (left != 3 || right != 2): return 2
	int[2] values
	values[0] = 10
	values[1] = 20
	values[ast_statement_mark(1)] += ast_statement_mark(2)
	if (ast_statement_trace != 12 || values[1] != 22): return 3
	ast_statement_pair pair
	pair = ast_statement_make(ast_statement_mark(3))
	if (pair.first != 3 || pair.second != 4 || ast_statement_trace != 123): return 4
	ast_statement_make(8)
	for i in range(3): ast_statement_make(i)
	pair.first = ast_statement_make(9).second
	if (pair.first != 10): return 5
	list[int] items = new list[int]
	items.push(left)
	items.length
	items[0]++
	if (items[0] != 4): return 6
	items.length
	items[0] = 5
	if (items[0] != 5): return 9
	items.free()
	int* address = &right
	left
	*address = 7
	if (right != 7): return 7
	if 1 { left++; right = left + 2; }
	if (left != 4 || right != 6): return 8
	left
	++left
	left++
	--left
	if (left != 5): return 10
	values.length
	values[0] = left
	if (values[0] != 5): return 11
	return 0
