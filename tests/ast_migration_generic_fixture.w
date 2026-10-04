import lib.lib
import lib.utf8

struct ast_generic_record:
	int number
	int tag

int ast_generic_order
int ast_generic_mark(int n):
	ast_generic_order = ast_generic_order * 10 + n
	return n

T ast_generic_ident[T](T value): return value
T ast_generic_sum[T](T a, T b): return a + b
void ast_generic_set[K, V](map[K, V] values, K key, V value): values[key] = value
void ast_generic_consume[T](T value): pass

int main():
	if (ast_generic_ident[int](ast_generic_mark(1)) + ast_generic_ident[int](ast_generic_mark(2)) != 3): return 1
	if (ast_generic_order != 12): return 2
	if (ast_generic_sum[int16](-7, 2) != -5): return 3
	if (ast_generic_sum[float32](1.25, 0.25) != 1.5): return 4
	if (ast_generic_ident[string](c"text") != s"text"): return 5
	char* name = ast_generic_ident[char*](c"name")
	if (strcmp(name, c"name") != 0): return 6
	ast_generic_record record = ast_generic_ident[ast_generic_record](ast_generic_record(7, 3))
	if (record.number != 7 || record.tag != 3): return 7
	if (ast_generic_ident[ast_generic_record](record).number != 7): return 8
	map[int, int] values = new map[int, int]
	ast_generic_set[int, int](values, 2, 42)
	if (values[2] != 42): return 9
	ast_generic_consume[int](9)
	if (ast_generic_ident[int](ast_generic_ident[int](5)) != 5): return 10
	if (f"{ast_generic_ident[int](42):04}" != s"0042"): return 11
	return 0
