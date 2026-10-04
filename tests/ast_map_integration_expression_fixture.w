# Composition across generic record returns, aliases, array-key decay,
# snapshot receivers and call-bearing boolean bitwise chains.
type ast_map_int_alias = int
type ast_map_float_alias = float32

struct ast_map_delta:
	int value

struct ast_map_box:
	map[int, int] values
	int marker

int ast_map_integration_order

int ast_map_integration_mark(int n):
	ast_map_integration_order = ast_map_integration_order * 10 + n
	return n

T ast_map_integration_identity[T](T value): return value

ast_map_delta ast_map_integration_delta():
	return ast_map_delta(ast_map_integration_mark(2))

ast_map_box ast_map_integration_box(map[int, int] values):
	return ast_map_box(values, ast_map_integration_mark(1))

int main():
	map[ast_map_int_alias, ast_map_int_alias] values = new map[ast_map_int_alias, ast_map_int_alias]
	if (values.add(7, ast_map_integration_identity[ast_map_delta](ast_map_integration_delta()).value) != 2): return 1
	if (ast_map_integration_order != 2): return 2
	ast_map_integration_order = 0
	list[int] keys = ast_map_integration_box(values).values.keys()
	if (keys.length != 1 || keys[0] != 7 || ast_map_integration_order != 1): return 3
	if (((values.add(8) > 0) & (keys[:].length > 0)) == 0): return 4
	if (values[8] != 1): return 5
	map[int, ast_map_float_alias] floats = new map[int, ast_map_float_alias]
	if (floats.add(1, cast(ast_map_float_alias, 1.5)) != 1.5): return 6
	if (floats.add(1) != 2.5): return 7
	list[ast_map_float_alias] decimals = floats.values()
	if (decimals.length != 1 || decimals[0] != 2.5): return 8
	char[4] word
	word[0] = 'k'
	word[1] = 'e'
	word[2] = 'y'
	word[3] = 0
	map[char*, int] words = new map[char*, int]
	if (words.add(word, ast_map_integration_identity[int](3)) != 3): return 9
	if (words.add(c"key") != 4): return 10
	list[char*] names = words.keys()
	if (names.length != 1 || names[0][0] != 'k'): return 11
	list[int] counts = words.values()
	if (counts[0] != 4): return 12
	keys.free()
	decimals.free()
	names.free()
	counts.free()
	values.free()
	floats.free()
	words.free()
	return 0
