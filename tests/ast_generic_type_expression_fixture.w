import lib.result
import structures.deque

struct ast_type_box[T]:
	T value
	int tag

struct ast_type_pair[K, V]:
	K key
	V value

type ast_type_integer = int

int main():
	ast_type_box[int] value
	value.value = 7
	value.tag = 8
	ast_type_box[int]* address = cast(ast_type_box[int]*, &value)
	if (address.value != 7 || address.tag != 8): return 1
	if (sizeof(ast_type_box[int]) != 2 * __word_size__): return 2
	if (sizeof(ast_type_box[int]***) != __word_size__): return 3
	if ((cast(ast_type_box[ast_type_integer]*, address)).value != 7): return 4
	ast_type_box[ast_type_box[int]] nested
	nested.value = value
	nested.tag = 9
	if (sizeof(ast_type_box[ast_type_box[int]]) != 3 * __word_size__): return 5
	if ((cast(ast_type_box[ast_type_box[int]]*, &nested)).value.tag != 8): return 6
	ast_type_pair[int, char*] pair
	pair.key = 10
	pair.value = c"hello"
	if (sizeof(ast_type_pair[int, char*]) != 2 * __word_size__): return 7
	if ((cast(ast_type_pair[int, char*]*, &pair)).key != 10): return 8
	list[ast_type_box[int]] boxes = new list[ast_type_box[int]]
	boxes.push(value)
	if (boxes[0].value != 7): return 9
	if (sizeof(map[int, ast_type_box[int]]) != __word_size__): return 10
	boxes.free()
	wresult[int]* result = result_new_ok[int](11)
	if (result_take_or[int](result, 0) != 11): return 11
	deque[int]* values = deque_new[int]()
	deque_push_back[int](values, 12)
	deque_push_front[int](values, 13)
	if (deque_pop_back[int](values) != 12): return 12
	if (deque_pop_front[int](values) != 13): return 13
	deque_free[int](values)
	return 0
