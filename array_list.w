uint length
uint capacity
any* array









void push(**args):
	ensure(args.length)
	for any value in args:
		array[capacity++] = value


void extend(iterator.any it):
	for value in it:
		push(value)


any* pop():
	assert(length > 0)
	return array[--capacity]


void insert(uint index, **args):
	uint n = args.length
	ensure(n)
	uint start = array + index * uint.length
	uint after_insert = start + n
	memmove(start, after_insert, n)
	for i, value in args.enumerate():
		array[index + i] = value


any* iterator():
	for i in range(length):
		yield array[i]


# value = arr[]
any* get(uint index):
	assert(index < length)
	return array[index]


# arr[index] = value
any* set(uint index, any* value):
	assert(index < length)
	array[index] = value


/*
locking_array_list
	read_lock: []
	range_lock: push, extend, pop, insert
	iterator_lock: 
*/



