/*
Generic ring-buffer deque (issue #360). Not auto-imported: ordinary
'import structures.deque'.

deque[T] stores its elements in a circular growable array: push and
pop at either end are O(1) amortized, indexed access O(1). Growth
doubles the buffer and linearizes the contents. Element count reads as
d.length, matching the built-in containers' .length convention.

Payload policy: keep T word-sized (int, char, bool, pointers) like
wresult[T] (lib/result.w); put aggregates behind a pointer.

Iteration: 'for T x in d' walks front to back. Do not mutate the deque
while iterating.

Traps (container convention, like the built-in list): pops and peeks
on an empty deque print what trapped and a stack trace, then exit(1);
deque_get/deque_set echo the index and length.

Generic calls need explicit type arguments (deque_push_back[int](d, 5)):
inference cannot see through the deque[T]* parameter shape
(docs/projects/generics.md).
*/
import lib.lib
import lib.stack_trace


struct deque[T]:
	int capacity
	int length
	int head
	T* items


void deque_trap(char* message):
	println2(message)
	print_stack_trace()
	exit(1)


# Mirrors the built-in containers' index trap: echo the index and the
# length, print a stack trace, exit(1).
void deque_index_trap(char* what, int index, int length):
	print2(what)
	print2(c": index ")
	print2(itoa(index))
	print2(c", length ")
	print2(itoa(length))
	println2(c"")
	print_stack_trace()
	exit(1)


deque[T]* deque_new_sized[T](int capacity):
	if (capacity < 4):
		capacity = 4
	# four word-sized fields on every instantiation (payload policy)
	deque[T]* d = cast(deque[T]*, malloc(4 * __word_size__))
	d.capacity = capacity
	d.length = 0
	d.head = 0
	d.items = cast(T*, malloc(capacity * __word_size__))
	return d


deque[T]* deque_new[T]():
	return deque_new_sized[T](8)


# Physical slot of logical index i (0 = front). No bounds check: the
# public accessors guard first.
int deque_physical[T](deque[T]* d, int i):
	int p = d.head + i
	if (p >= d.capacity):
		p = p - d.capacity
	return p


# Double the buffer and linearize: the front moves to items[0].
void deque_grow[T](deque[T]* d):
	int new_capacity = d.capacity * 2
	T* new_items = cast(T*, malloc(new_capacity * __word_size__))
	int i = 0
	while (i < d.length):
		new_items[i] = d.items[deque_physical[T](d, i)]
		i = i + 1
	free(cast(void*, d.items))
	d.items = new_items
	d.capacity = new_capacity
	d.head = 0


void deque_push_back[T](deque[T]* d, T value):
	if (d.length == d.capacity):
		deque_grow[T](d)
	d.items[deque_physical[T](d, d.length)] = value
	d.length = d.length + 1


void deque_push_front[T](deque[T]* d, T value):
	if (d.length == d.capacity):
		deque_grow[T](d)
	int h = d.head - 1
	if (h < 0):
		h = d.capacity - 1
	d.head = h
	d.items[h] = value
	d.length = d.length + 1


T deque_peek_front[T](deque[T]* d):
	if (d.length == 0):
		deque_trap(c"peek_front on empty deque")
	return d.items[d.head]


T deque_peek_back[T](deque[T]* d):
	if (d.length == 0):
		deque_trap(c"peek_back on empty deque")
	return d.items[deque_physical[T](d, d.length - 1)]


T deque_pop_front[T](deque[T]* d):
	if (d.length == 0):
		deque_trap(c"pop_front on empty deque")
	T value = d.items[d.head]
	d.head = d.head + 1
	if (d.head >= d.capacity):
		d.head = 0
	d.length = d.length - 1
	return value


T deque_pop_back[T](deque[T]* d):
	if (d.length == 0):
		deque_trap(c"pop_back on empty deque")
	d.length = d.length - 1
	return d.items[deque_physical[T](d, d.length)]


T deque_get[T](deque[T]* d, int index):
	if ((index < 0) || (index >= d.length)):
		deque_index_trap(c"deque index out of range", index, d.length)
	return d.items[deque_physical[T](d, index)]


void deque_set[T](deque[T]* d, int index, T value):
	if ((index < 0) || (index >= d.length)):
		deque_index_trap(c"deque index out of range", index, d.length)
	d.items[deque_physical[T](d, index)] = value


int deque_length[T](deque[T]* d):
	return d.length


void deque_clear[T](deque[T]* d):
	d.length = 0
	d.head = 0


void deque_free[T](deque[T]* d):
	free(cast(void*, d.items))
	free(d)


# Cursor protocol (grammar/for_statement.w): front-to-back iteration.
int deque_iter_begin[T](deque[T]* d):
	return 0


int deque_iter_done[T](deque[T]* d, int cursor):
	return cursor >= d.length


int deque_iter_next[T](deque[T]* d, int cursor):
	return cursor + 1


T deque_iter_value[T](deque[T]* d, int cursor):
	if (cursor >= d.length):
		deque_index_trap(c"deque iterator out of range", cursor, d.length)
	return d.items[deque_physical[T](d, cursor)]
