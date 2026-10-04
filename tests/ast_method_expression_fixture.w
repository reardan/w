struct ast_method_point:
	int x
	int y

int ast_method_point_scale(ast_method_point* self, int factor = 2): return self.x * factor + self.y
int scale(ast_method_point* self, int factor = 2): return 100 + factor + self.x
int total(ast_method_point* self): return self.x + self.y
ast_method_point shifted(ast_method_point* self, int dx): return ast_method_point(self.x + dx, self.y)

ast_method_point ast_method_point_added(ast_method_point* self, int... values):
	ast_method_point result = ast_method_point(self.x, self.y)
	for int i in range(values.length): result.x = result.x + values[i]
	return result

ast_method_point moved(ast_method_point* self, ast_method_point delta):
	return ast_method_point(self.x + delta.x, self.y + delta.y)

int clamp(int value, int low = 0, int high = 10):
	if (value < low): return low
	if (value > high): return high
	return value

int add_all(int value, int... values):
	for int i in range(values.length): value = value + values[i]
	return value

float scaled_float(float value, int factor): return value * factor
int text_size(string value): return value.length
int item_count(list[int] values): return values.length
int pair_count(map[int, int] values): return values.length
int key_count(set[int] values): return values.length
int view_sum(int[] values): return values[0] + values[1]

int ast_method_order
ast_method_point* ast_method_get(ast_method_point* point):
	ast_method_order = ast_method_order * 10 + 1
	return point
int ast_method_mark(int value):
	ast_method_order = ast_method_order * 10 + 2
	return value

type ast_method_callback = fn(int) -> int
struct ast_method_field:
	ast_method_callback* action
int ast_method_increment(int value): return value + 1
int ast_method_field_action(ast_method_field* self, int value): return value + 100

int main():
	ast_method_point point = ast_method_point(3, 4)
	if (point.scale() != 10): return 1
	if (point.scale(3) != 13): return 2
	ast_method_point* address = &point
	if (address.scale() != 10 || point.total() != 7): return 3
	if (ast_method_get(&point).scale(ast_method_mark(3)) != 13): return 4
	if (ast_method_order != 12): return 5
	if (point.shifted(2).x != 5): return 6
	if (point.shifted(2).scale() != 14): return 7
	if (ast_method_point(5, 6).scale() != 16): return 8
	int value = 15
	if (value.clamp() != 10 || value.clamp(1, 20) != 15): return 9
	if (value.add_all() != 15 || value.add_all(1, 2, 3) != 21): return 10
	if ((2.5).scaled_float(2) != 5.0): return 11
	if (s"hello".text_size() != 5): return 12
	list[int] items = list[int]{1, 2}
	map[int, int] pairs = map[int, int]{1: 2}
	set[int] keys = set[int]{1, 2, 3}
	if (items.item_count() != 2 || pairs.pair_count() != 1 || keys.key_count() != 3): return 13
	int[2] array
	array[0] = 7
	array[1] = 8
	if (array.view_sum() != 15): return 14
	ast_method_field field
	field.action = ast_method_increment
	if (field.action(3) != 4): return 15
	if (point.added().x != 3 || point.added(1, 2).scale() != 16): return 16
	if (point.moved(point.shifted(1)).x != 7): return 17
	items.free()
	pairs.free()
	keys.free()
	return 0
