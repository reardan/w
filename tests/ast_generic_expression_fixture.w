import lib.container
import lib.array

struct ast_generic_record:
	int a
	int b

struct ast_generic_fresh:
	int value

type ast_generic_alias = int

T ast_generic_identity[T](T value): return value

T ast_generic_relay[T](T value): return ast_generic_identity[T](value)

T ast_generic_add[T](T a, T b): return a + b

T* ast_generic_pointer[T](int raw): return cast(T*, raw)

int ast_generic_ignore[T](void* value): return sizeof(T) + (value != 0)

int ast_generic_record_sum(ast_generic_record value): return value.a + value.b

int ast_generic_sequence

int ast_generic_tick(int value):
	ast_generic_sequence = ast_generic_sequence * 10 + value
	return value

struct ast_generic_box[T]:
	T value

T ast_generic_unbox[T](ast_generic_box[T]* box): return box.value

T ast_generic_first[T](T[] values): return values[0]

void ast_generic_zero[T](T[] values): values[0] = 0


int main():
	if ((ast_generic_identity[int](3) + ast_generic_identity[int](4)) != 7): return 1
	if ((ast_generic_identity[ast_generic_alias](5) + ast_generic_identity[int](6)) != 11): return 2
	if ((ast_generic_add[int](ast_generic_identity[int](7), ast_generic_identity[int](8))) != 15): return 3
	if ((ast_generic_add[int](ast_generic_tick(1), ast_generic_tick(2))) != 3): return 4
	if (ast_generic_sequence != 12): return 5
	ast_generic_record record
	record.a = 9
	record.b = 10
	ast_generic_record copied = ast_generic_identity[ast_generic_record](record)
	if (copied.a != 9 || copied.b != 10): return 6
	if ((ast_generic_record_sum(ast_generic_identity[ast_generic_record](record))) != 19): return 7
	if ((ast_generic_identity[ast_generic_record](record).b) != 10): return 8
	if ((ast_generic_pointer[char](0)) != 0): return 9
	if ((ast_generic_ignore[int](cast(ast_generic_fresh*, 0))) != __word_size__): return 10
	list[int] values = new list[int]
	values.push(12)
	if ((ast_generic_identity[list[int]](values).length) != 1): return 11
	map[int, int] mapping = new map[int, int]
	mapping[1] = 4
	if ((ast_generic_identity[map[int, int]](mapping)[1]) != 4): return 12
	list_free[int](values)
	map_free[int, int](mapping)
	if ((ast_generic_identity[float](1.5)) != 1.5): return 13
	string text = ast_generic_identity[string]("abc")
	if (text.length != 3): return 14
	if ((ast_generic_relay[int](17)) != 17): return 15
	ast_generic_box[int] box
	box.value = 31
	if ((ast_generic_unbox[int](&box)) != 31): return 16
	int[] array = new int[2]
	array[0] = 32
	if ((ast_generic_first[int](array)) != 32): return 17
	ast_generic_zero[int](array)
	if (array[0] != 0): return 18
	array_free[int](array)
	return 0
