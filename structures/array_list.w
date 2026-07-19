/*
Growable array of word values; every array_list is an independent heap
object.

Kept (issue #145) as the library exemplar of the T_iter_begin/done/
next/value cursor protocol that for-in lowers to for user-defined
containers (docs/projects/iteration.md, tests/for_container_test.w).
New code should normally use the built-in list[T] instead.
*/
import lib.lib
import lib.assert


struct array_list:
	int capacity
	int length
	int* items


array_list* array_list_new_sized(int capacity):
	if (capacity < 4):
		capacity = 4
	array_list* list = new array_list()
	list.capacity = capacity
	list.length = 0
	list.items = malloc(capacity * __word_size__)
	return list


array_list* array_list_new():
	return array_list_new_sized(8)


void array_list_ensure(array_list* list, int extra):
	int needed = list.length + extra
	if (needed > list.capacity):
		int new_capacity = list.capacity * 2
		if (new_capacity < needed):
			new_capacity = needed
		# oldlen is the allocation size (capacity words), not length —
		# see structures/string.w string_reserve.
		list.items = cast(int*, realloc(list.items, list.capacity * __word_size__, new_capacity * __word_size__))
		list.capacity = new_capacity


void array_list_push(array_list* list, int value):
	array_list_ensure(list, 1)
	list.items[list.length] = value
	list.length = list.length + 1


int array_list_pop(array_list* list):
	assert1(list.length > 0)
	list.length = list.length - 1
	return list.items[list.length]


int array_list_get(array_list* list, int index):
	assert1(index < list.length)
	return list.items[index]


int array_list_iter_begin(array_list* list):
	return 0


# Do not mutate the list while iterating.
int array_list_iter_done(array_list* list, int cursor):
	return cursor >= list.length


int array_list_iter_next(array_list* list, int cursor):
	return cursor + 1


int array_list_iter_value(array_list* list, int cursor):
	assert1(cursor < list.length)
	return list.items[cursor]


void array_list_set(array_list* list, int index, int value):
	assert1(index < list.length)
	list.items[index] = value


void array_list_remove(array_list* list, int index):
	assert1(index < list.length)
	int i = index
	while (i + 1 < list.length):
		list.items[i] = list.items[i + 1]
		i = i + 1
	list.length = list.length - 1


void array_list_insert(array_list* list, int index, int value):
	assert1(index <= list.length)
	array_list_ensure(list, 1)
	int i = list.length
	while (i > index):
		list.items[i] = list.items[i - 1]
		i = i - 1
	list.items[index] = value
	list.length = list.length + 1


void array_list_free(array_list* list):
	free(list.items)
	free(list)
