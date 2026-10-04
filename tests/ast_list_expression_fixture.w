struct ast_list_record:
	int number
	int16 small

int ast_list_order
int ast_list_index(int n):
	ast_list_order = ast_list_order * 10 + n
	return n

int main():
	list[int] values = new list[int]
	values.push(10)
	values.push(20)
	values.push(30)
	if ((values[ast_list_index(1)] + values[ast_list_index(2)]) != 50): return 1
	if (ast_list_order != 12): return 2
	if ((values[0] += values[2]) != 40): return 3
	if ((values[1] = values[0]) != 40): return 4
	list[int16] small = new list[int16]
	small.push(300)
	if ((small[0] + 2) != 302): return 5
	list[string] words = new list[string]
	words.push(s"hello")
	if ((words[0] == s"hello") != true): return 6
	list[ast_list_record] records = new list[ast_list_record]
	ast_list_record first
	first.number = 42
	first.small = 7
	records.push(first)
	if ((records[0].number + records[0].small) != 49): return 7
	if ((records[0].small += 2) != 9): return 8
	list[list[int]] nested = new list[list[int]]
	nested.push(values)
	if ((nested[0][2]) != 30): return 9
	int* address = (&values[2])
	if (*address != 30): return 10
	return 0
