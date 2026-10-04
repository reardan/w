import lib.lib

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
	if 1: (records.insert(0, first))
	if (records[1].small != 9): return 11
	if 1: (values.insert(ast_list_index(0), ast_list_index(9)))
	if (ast_list_order != 1209): return 12
	if 1: (values.remove(1))
	if ((values.pop()) != 30): return 13
	if (values.length != 2): return 14
	if ((small.pop()) != 300): return 15
	if 1: (small.push(-123))
	if ((small.pop()) != -123): return 21
	list[float32] reals = (new list[float32])
	if 1: (reals.push(1.5))
	if ((reals.pop()) != 1.5): return 22
	if 1: (words.push(c"world"))
	if ((words[1] == s"world") != true): return 16
	if ((sizeof(list[int])) != __word_size__): return 17
	list[int] nil = (cast(list[int], 0))
	if ((nil != 0)): return 18
	map[char*, int] mapping = (new map[char*, int])
	set[int] keys = (new set[int])
	if ((mapping.length + keys.length) != 0): return 19
	if 1: (values.clear())
	if (values.length != 0): return 20
	if 1: (values.free())
	if 1: (small.free())
	if 1: (records.free())
	if 1: (words.free())
	if 1: (reals.free())
	return 0
