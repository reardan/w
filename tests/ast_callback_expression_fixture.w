type ast_callback_op = fn(int, int) -> int
type ast_callback_float = fn(float32) -> float32
type ast_callback_sink = fn(int) -> void

struct ast_callback_box:
	ast_callback_op* op

int ast_callback_order
int ast_callback_add(int a, int b): return a + b
int ast_callback_sub(int a, int b): return a - b
float32 ast_callback_scale(float32 n): return n * 2
void ast_callback_record(int n): ast_callback_order = ast_callback_order * 10 + n
ast_callback_op* ast_callback_factory(): return ast_callback_add
int ast_callback_apply(ast_callback_op* op, int a, int b): return (op(a, b))
int ast_callback_change(ast_callback_op** slot):
	*slot = ast_callback_sub
	return 10

int main():
	ast_callback_op* op = (ast_callback_add)
	if ((op(2, 3)) != 5): return 1
	if ((ast_callback_apply(ast_callback_sub, 10, 3)) != 7): return 2
	if ((ast_callback_factory()(20, 22)) != 42): return 3
	ast_callback_box box
	box.op = ast_callback_sub
	if ((box.op(20, 3)) != 17): return 4
	if 1: (op = ast_callback_add)
	if ((op(ast_callback_change(&op), 3)) != 7): return 5
	int raw_address = (cast(int, ast_callback_add))
	if ((raw_address(20, 22)) != 42): return 6
	if (((ast_callback_add)(2, 3)) != 5): return 7
	ast_callback_float* scale = ast_callback_scale
	if ((scale(1.5)) != 3.0): return 8
	ast_callback_sink* sink = ast_callback_record
	if 1: (sink(1))
	if 1: (sink(2))
	if (ast_callback_order != 12): return 9
	if ((op == ast_callback_sub) != true): return 10
	# Word-address indexing deliberately keeps the old byte-wide behavior.
	char value = 'A'
	int raw = cast(int, &value)
	if ((raw[0]) != 'A'): return 11
	if 1: (raw[0] = 'B')
	if (value != 'B'): return 12
	if 1: (raw[0] += 1)
	if (value != 'C'): return 13
	if (((raw + 0)[0]) != 'C'): return 14
	return 0
