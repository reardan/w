struct ast_callback_record:
	int x
	int y

type ast_list_unary = fn(int) -> int
type ast_list_binary = fn(int, int) -> int

int ast_list_callback_order

int ast_list_double(int value): return value * 2
int ast_list_odd(int value): return value % 2
int ast_list_sum(int a, int b): return a + b
int ast_list_desc(int a, int b): return b - a
float32 ast_list_half(int value): return value * 0.5

int ast_list_record_order(ast_callback_record* a, ast_callback_record* b):
	return a.y - b.y

list[int] ast_list_callback_receiver(list[int] values):
	ast_list_callback_order = ast_list_callback_order * 10 + 1
	return values

ast_list_binary* ast_list_callback_function():
	ast_list_callback_order = ast_list_callback_order * 10 + 2
	return ast_list_sum

int ast_list_callback_initial():
	ast_list_callback_order = ast_list_callback_order * 10 + 3
	return 10

int main():
	list[int] values = list[int]{3, 1, 2}
	doubled := values.map(ast_list_double)
	if (doubled[0] != 6 || doubled[1] != 2 || doubled[2] != 4): return 1
	ast_list_unary* mapper = ast_list_double
	from_pointer := values.map(mapper)
	if (from_pointer[0] != 6): return 2
	fractions := values.map(ast_list_half)
	if (fractions[0] != 1.5 || fractions[1] != 0.5): return 3
	odd := values.filter(ast_list_odd)
	if (odd.length != 2 || odd[0] != 3 || odd[1] != 1): return 4
	if (values.reduce(ast_list_sum, 10) != 16): return 5
	if (ast_list_callback_receiver(values).reduce(ast_list_callback_function(), ast_list_callback_initial()) != 16): return 6
	if (ast_list_callback_order != 123): return 7
	sorted := values.sorted_by(ast_list_desc)
	if (sorted[0] != 3 || sorted[1] != 2 || values[1] != 1): return 8
	ast_list_binary* compare = ast_list_desc
	values.sort_by(compare)
	if (values[0] != 3 || values[1] != 2 || values[2] != 1): return 9
	list[ast_callback_record] records = list[ast_callback_record]{ast_callback_record(1, 4), ast_callback_record(2, 3)}
	copies := records.sorted_by(ast_list_record_order)
	if (copies[0].x != 2 || records[0].x != 1): return 10
	records.sort_by(ast_list_record_order)
	if (records[0].x != 2): return 11
	list[int] empty = new list[int]
	if (empty.reduce(ast_list_sum, 7) != 7): return 12
	values.free()
	doubled.free()
	from_pointer.free()
	fractions.free()
	odd.free()
	sorted.free()
	records.free()
	copies.free()
	empty.free()
	return 0
