/*
Runtime for the built-in typed list[T] container.

The compiler lowers list syntax (new list[T], list[T]{...} literals,
l[index], l.push(v), l.pop(), l.length and for x in l) to these helpers.
Storage is byte-addressed: every element occupies element_size bytes, so
list[char] stays compact and wider element types keep their natural width.
Word-sized elements travel through the helpers as plain words; the
compiler loads and stores elements through __w_list_addr with the element
type's own width, so language semantics match slices and arrays.
*/
import lib.memory


struct __w_list:
	int capacity
	int length
	int element_size
	char* items


void __w_list_assert(int condition):
	if (condition == 0):
		exit(1)


__w_list* __w_list_new(int element_size):
	__w_list_assert(element_size > 0)
	int capacity = 8
	__w_list* list = malloc(4 * __word_size__)
	list.capacity = capacity
	list.length = 0
	list.element_size = element_size
	list.items = malloc(capacity * element_size)
	return list


void __w_list_ensure(__w_list* list, int extra):
	int needed = list.length + extra
	if (needed > list.capacity):
		int new_capacity = list.capacity * 2
		if (new_capacity < needed):
			new_capacity = needed
		list.items = realloc(list.items, list.length * list.element_size, new_capacity * list.element_size)
		list.capacity = new_capacity


# Address of element index; the compiler reads and writes elements through
# this so l[i] is a normal lvalue of the element type.
char* __w_list_addr(__w_list* list, int index):
	__w_list_assert(index >= 0)
	__w_list_assert(index < list.length)
	return list.items + index * list.element_size


void __w_list_store_word(char* addr, int element_size, int value):
	if (element_size == 1):
		addr[0] = value
	else if (element_size == 2):
		int16* addr16 = cast(int16*, addr)
		addr16[0] = value
	else if (element_size == 4):
		int32* addr32 = cast(int32*, addr)
		addr32[0] = value
	else:
		int* addr_word = cast(int*, addr)
		addr_word[0] = value


int __w_list_load_word(char* addr, int element_size):
	if (element_size == 1):
		return addr[0]
	if (element_size == 2):
		int16* addr16 = cast(int16*, addr)
		return addr16[0]
	if (element_size == 4):
		int32* addr32 = cast(int32*, addr)
		return addr32[0]
	int* addr_word = cast(int*, addr)
	return addr_word[0]


void __w_list_push(__w_list* list, int value):
	__w_list_ensure(list, 1)
	__w_list_store_word(list.items + list.length * list.element_size, list.element_size, value)
	list.length = list.length + 1


int __w_list_pop(__w_list* list):
	__w_list_assert(list.length > 0)
	list.length = list.length - 1
	return __w_list_load_word(list.items + list.length * list.element_size, list.element_size)


int __w_list_length(__w_list* list):
	return list.length


int __w_list_iter_begin(__w_list* list):
	return 0


# Do not mutate the list while iterating.
int __w_list_iter_done(__w_list* list, int cursor):
	return cursor >= list.length


int __w_list_iter_next(__w_list* list, int cursor):
	return cursor + 1


int __w_list_iter_value(__w_list* list, int cursor):
	__w_list_assert(cursor < list.length)
	return __w_list_load_word(list.items + cursor * list.element_size, list.element_size)


void __w_list_free(__w_list* list):
	free(list.items)
	free(list)
