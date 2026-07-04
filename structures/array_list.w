/*
Growable array of word values.

Unlike structures/list.w (a single global list), every array_list is an
independent heap object.
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
	array_list* list = malloc(12)
	list.capacity = capacity
	list.length = 0
	list.items = malloc(capacity * 4)
	return list


array_list* array_list_new():
	return array_list_new_sized(8)


void array_list_ensure(array_list* list, int extra):
	int needed = list.length + extra
	if (needed > list.capacity):
		int new_capacity = list.capacity * 2
		if (new_capacity < needed):
			new_capacity = needed
		list.items = cast(int*, realloc(list.items, list.length * 4, new_capacity * 4))
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
