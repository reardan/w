int ast_metadata_length(string text): return (text.length)
int ast_metadata_first(int[] values): return (values.data[0] + values.length)
list[int] ast_metadata_list(list[int] values): return (values)
map[int, int] ast_metadata_map(map[int, int] values): return (values)
set[int] ast_metadata_set(set[int] values): return (values)

int main():
	string text = s"abc"
	if ((text.length) != 3): return 1
	if ((text.data[1]) != 'b'): return 2
	if ((ast_metadata_length(text)) != 3): return 3
	int[4] array
	array[0] = 38
	if ((array.length) != 4): return 4
	if ((array.data[0]) != 38): return 5
	if 1: (array.data[1] = 7)
	if (array[1] != 7): return 6
	if ((ast_metadata_first(array)) != 42): return 7
	if 1: (array[text.length] = 99)
	if (array[3] != 99): return 8
	list[int] values = new list[int]
	values.push(42)
	if ((ast_metadata_list(values).length) != 1): return 9
	if ((ast_metadata_list(values)[0]) != 42): return 10
	list[int] copy = 0
	if 1: (copy = values)
	if ((copy == values) != true): return 11
	map[int, int] mapping = new map[int, int]
	mapping[1] = 42
	if ((ast_metadata_map(mapping).length) != 1): return 12
	set[int] keys = new set[int]
	keys.add(3)
	if ((ast_metadata_set(keys).length) != 1): return 13
	int word = 42
	int raw = cast(int, &word)
	if ((*raw) != 42): return 14
	if 1: (*raw = 99)
	if (word != 99): return 15
	return 0
