import lib.lib

struct ast_default_record:
	int x

int ast_default_factory_calls

list[int] ast_default_factory():
	ast_default_factory_calls = ast_default_factory_calls + 1
	return list[int]{4}

ast_default_record* ast_default_pointer_factory():
	return new ast_default_record(17)

type ast_default_factory_type = fn() -> list[int]

int main():
	counts := new map[int, int](5)
	if (counts[8] != 5 || counts.length != 1): return 1
	counts[8] += 2
	if (counts[8] != 7 || counts[9] != 5): return 2
	reals := new map[int, float32](1.5)
	if (reals[3] != 1.5): return 3
	words := new map[int, string](c"missing")
	if (words[1] != s"missing"): return 4
	created := new map[int, list[int]](ast_default_factory)
	created[1].push(7)
	if (created[1].length != 2 || ast_default_factory_calls != 1): return 5
	if (created[2].length != 1 || ast_default_factory_calls != 2): return 6
	ast_default_factory_type* factory = ast_default_factory
	indirect := new map[int, list[int]](factory)
	if (indirect[3][0] != 4 || ast_default_factory_calls != 3): return 7
	automatic := new map[int, list[int16]]()
	automatic[1].push(8)
	if (automatic[2].length != 0 || automatic[1][0] != 8): return 8
	nested := new map[int, map[int, int]]()
	nested[1][2] += 3
	if (nested[1][2] != 3 || nested[1][9] != 0): return 9
	sets := new map[int, set[int]]()
	sets[1].add(4)
	if (!(4 in sets[1]) || (4 in sets[2])): return 10
	pointers := new map[int, ast_default_record*](ast_default_pointer_factory)
	if (pointers[1].x != 17 || pointers[1] == pointers[2]): return 11
	created[1].free()
	created[2].free()
	indirect[3].free()
	automatic[1].free()
	automatic[2].free()
	nested[1].free()
	sets[1].free()
	sets[2].free()
	free(pointers[1])
	free(pointers[2])
	counts.free()
	reals.free()
	words.free()
	created.free()
	indirect.free()
	automatic.free()
	nested.free()
	sets.free()
	pointers.free()
	return 0
