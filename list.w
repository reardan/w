/*
list
	append
	appendleft
	clear
	copy
	count
	extend
	extendleft
	index
	insert
	pop
	popleft
	remove
	reverse
	rotate

sub classes / specialty versions
	LinkedList
	ArrayList
	FlatList
	DoublyLinkedList
	RingBuffer

*/
import math

# Depends on codegen indirectly for load_int/save_int for now
# This will be removed once int*[] lookups are working.

int capacity
int length
char* array


void create():
	array = 0
	length = capacity = 0


void die():
	# TODO: free children
	free(array)
	create()


void resize(int new_capacity):
	array = realloc(array, capacity * 4, new_capacity * 4)
	assert(array != 0)
	capacity = new_capacity


void ensure(int n):
	if (length + n > capacity):
		resize(max(length * 2, n))


void push(int value):
	ensure(1)
	save_int(array + length * 4, value)
	# array[length] = value
	length = length + 1


int get(int i):
	return load_int(array + i * 4)


int* pop():
	if(length == 0):
		return 0 /* null indicates empty: caller should check this */
	length = length - 1
	# int result = array[length]
	int result = load_int(array + length * 4)
	return result
