import tests.import_alias_type_helper as types
import tests.subfolder as sub
import tests.level1.level2.level3.level_file as deep

type ast_qualified_callback = fn() -> int

int main():
	types.alias_point point = types.alias_point(20, 22)
	if (point.x + point.y != 42): return 1
	types.alias_point* heap = new types.alias_point(y: 7, x: 5)
	if (heap.x + heap.y != 12): return 2
	types.alias_point* empty = new types.alias_point
	empty.x = 9
	if (empty.x != 9): return 3
	int words = sizeof(types.alias_point) / sizeof(types.alias_word)
	if (words != 2): return 4
	types.alias_word value = cast(types.alias_word, 7)
	if (value != 7): return 5
	types.alias_point[] points = new types.alias_point[2]
	points[0] = types.alias_point(3, 4)
	if (points[0].y != 4): return 6
	deep.level_file_variable = sub.subfolder_value()
	if (deep.level_file_variable != 1337): return 7
	ast_qualified_callback* callback = types.alias_type_helper_value
	if (callback() != 1337): return 8
	# The alias takes precedence over a local with the same name.
	int deep = 4
	deep.level_file_variable += deep
	if (deep.level_file_variable != 1341): return 9
	return 0
