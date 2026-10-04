import lib.lib

struct ast_map_record:
	int number
	int16 small

int ast_map_order
int ast_map_key(int n):
	ast_map_order = ast_map_order * 10 + n
	return n

map[int, int] ast_map_receiver(map[int, int] values):
	ast_map_order = ast_map_order * 10 + 1
	return values

int ast_map_sum(ast_map_record value): return value.number + value.small

int main():
	map[int, int] values = new map[int, int]
	if 1: (values[2] = 10)
	if 1: (values[3] = 20)
	if ((values[2] + values[3]) != 30): return 1
	if ((ast_map_receiver(values)[ast_map_key(2)] += ast_map_key(3)) != 13): return 2
	if (ast_map_order != 123): return 3
	if ((2 in values) != true): return 4
	if ((4 in values) != false): return 5
	if 1: (values[values[2] - 10] = values[2])
	if (values[3] != 13): return 6
	map[int, map[int, int]] nested = new map[int, map[int, int]]
	nested[1] = values
	if ((nested[1][2]) != 13): return 7
	if 1: (nested[1][2] = values[3] = 21)
	if (values[2] != 21 || values[3] != 21): return 8
	map[char*, int] names = new map[char*, int]
	if 1: (names[c"hello"] = 42)
	if (("hello" in names) != true): return 9
	if ((names["hello"]) != 42): return 10
	map[string, string] words = new map[string, string]
	if 1: (words[c"key"] = c"value")
	if ((words[s"key"] == s"value") != true): return 11
	if ((s"key" in words) != true): return 12
	map[int, float32] reals = new map[int, float32]
	reals[1] = 1.5
	if ((reals[1] *= 2) != 3.0): return 13
	map[int, int16] small = new map[int, int16]
	small[1] = -123
	if ((small[1] += 3) != -120): return 14
	map[int, ast_map_record] records = new map[int, ast_map_record]
	ast_map_record first
	first.number = 10
	first.small = 3
	if 1: (records[1] = first)
	ast_map_record copy = (records[1])
	if (copy.number != 10 || copy.small != 3): return 15
	if ((ast_map_sum(records[1])) != 13): return 16
	if 1: (records[1].number = 20)
	if ((records[1].number + records[1].small) != 23): return 17
	set[int] keys = new set[int]
	keys.add(7)
	if ((7 in keys) != true): return 18
	if ((8 in keys) != false): return 19
	list[char*] strings = new list[char*]
	strings.push(c"name")
	if (("name" in strings) != true): return 20
	if ((c"other" in strings) != false): return 21
	list[int] numbers = new list[int]
	numbers.push(4)
	if ((4 in numbers) != true): return 22
	if ((5 in numbers) != false): return 23
	return 0
