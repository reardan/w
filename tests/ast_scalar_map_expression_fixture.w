import lib.lib

int ast_map_calls

int ast_map_key():
	ast_map_calls += 1
	return 7

int ast_map_read(map[int, int] m): return (m[7])
int ast_map_store(map[int, int] m): return (m[ast_map_key()] = 40)
int ast_map_add(map[int, int] m): return (m[ast_map_key()] += 2)

int main():
	map[int, int] values = new map[int, int]
	if ((ast_map_store(values)) != 40): return 1
	if (ast_map_calls != 1): return 2
	if ((ast_map_add(values)) != 42): return 3
	if (ast_map_calls != 2): return 4
	if ((ast_map_read(values)) != 42): return 5
	if 1: (values[values[7]] = values[7] + 1)
	if ((values[42]) != 43): return 6
	map[int, map[int, int]] nested = new map[int, map[int, int]]
	nested[1] = values
	if ((nested[1][7]) != 42): return 7
	if 1: (nested[1][7] *= 2)
	if ((values[7]) != 84): return 8
	map[char*, float32] floats = new map[char*, float32]
	floats[c"pi"] = 1.5
	if 1: (floats[c"pi"] += 0.5)
	if ((floats[c"pi"]) != 2.0): return 9
	map[string, int] text = new map[string, int]
	if 1: (text[c"answer"] = 42)
	if ((text[s"answer"]) != 42): return 10
	return 0
