type ast_default_callback = fn() -> int

int ast_default_calls

int ast_default_factory():
	ast_default_calls += 1
	return ast_default_calls * 10

int main():
	map[int, int] values = (new map[int, int](40))
	if (values[7] != 40): return 1
	values[7] += 2
	if (values[7] != 42 || values.length != 1): return 2
	map[int, float32] floats = (new map[int, float32](1.5))
	if (floats[1] != 1.5): return 3
	map[int, int] factory = (new map[int, int](ast_default_factory))
	if (factory[1] != 10 || factory[2] != 20): return 4
	if (factory[1] != 10 || ast_default_calls != 2): return 5
	ast_default_callback* callback = ast_default_factory
	map[int, int] indirect = (new map[int, int](callback))
	if (indirect[1] != 30 || ast_default_calls != 3): return 6
	map[int, map[int, int]] nested = (new map[int, map[int, int]]())
	nested[1][2] += 42
	if (nested[1][2] != 42 || nested.length != 1): return 7
	map[int, list[int]] lists = (new map[int, list[int]]())
	lists[1].push(42)
	if (lists[1][0] != 42 || lists[1].length != 1): return 8
	map[int, set[int]] sets = (new map[int, set[int]]())
	if (sets[1].length != 0 || sets.length != 1): return 9
	return 0
