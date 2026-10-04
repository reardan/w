import lib.mem

struct ast_infer_record:
	int x
	int y

T ast_infer_add[T](T a, T b): return a + b
T ast_infer_second[T](T a, T b): return b
T ast_infer_identity[T](T value): return value
T* ast_infer_pointer[T](T* value): return value
int ast_infer_size[T](T value): return sizeof(T)

T ast_infer_recursive[T](T value):
	if (value <= 1): return 1
	return value * ast_infer_recursive(value - 1)

int ast_infer_concrete[T](T value, float32 scale):
	return value * cast(int, scale)

type ast_infer_callback = fn(int) -> int
int ast_infer_increment(int value): return value + 1
int ast_infer_apply[T](T value, ast_infer_callback* callback): return callback(value)

int ast_infer_order
int ast_infer_mark(int value):
	ast_infer_order = ast_infer_order * 10 + value
	return value

int main():
	if (ast_infer_add(2, 3) != 5): return 1
	if (ast_infer_add(1.5, 2) != 3.5): return 2
	if (ast_infer_second(true, 2) != true): return 3
	if (ast_infer_add(ast_infer_mark(1), ast_infer_mark(2)) != 3): return 4
	if (ast_infer_order != 12): return 5
	if (ast_infer_add(ast_infer_add(1, 2), ast_infer_add[int](3, 4)) != 10): return 6
	if (ast_infer_add[int](ast_infer_add(1, 2), 4) != 7): return 7
	if (ast_infer_recursive(5) != 120): return 8
	int[3] source
	int[3] destination
	source[0] = 7
	source[1] = 8
	source[2] = 9
	int* src = &source[0]
	int* dst = &destination[0]
	mem_copy(dst, src, 3)
	if (destination[1] != 8): return 9
	mem_fill(dst, 6, 3)
	if (destination[0] != 6 || destination[2] != 6): return 10
	if (ast_infer_pointer(src)[2] != 9): return 11
	string text = ast_infer_identity(s"hello")
	if (text.length != 5): return 12
	values := ast_infer_identity(list[int16]{3, 4})
	if (values[1] != 4): return 13
	int[] view = ast_infer_identity(source)
	if (view[0] != 7 || view.length != 3): return 14
	ast_infer_record record = ast_infer_record(1, 2)
	if (ast_infer_size(record) != __word_size__ * 2): return 15
	if (ast_infer_concrete(3, 2) != 6): return 16
	ast_infer_callback* callback = ast_infer_increment
	if (ast_infer_apply(2, callback) != 3 || ast_infer_apply(3, ast_infer_increment) != 4): return 17
	values.free()
	return 0
