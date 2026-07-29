/*
Generic binary min-heap (issue #360). Not auto-imported: ordinary
'import structures.heap'.

heap[T] stores its elements in a growable array with the implicit-tree
layout: items[0] is the minimum, the children of slot i live at
2i+1/2i+2. heap_push and heap_pop are O(log n), heap_peek O(1),
heap_from_list O(n). Element count reads as h.length, matching the
built-in containers' .length convention.

Ordering: heap_new orders by the signed word compare ('<' on the
element values, list.sort's scalar ordering). heap_new_by takes a
comparator like list.sort_by: a heap_compare function returning
negative/zero/positive like strcmp, called with the element values.
Declare comparators over the word type (int) and cast pointer elements
back inside; see tests/heap_test.w for a char*-contents min-heap.

Payload policy: keep T word-sized (int, char, bool, pointers) like
wresult[T] (lib/result.w); put aggregates behind a pointer.

Iteration: 'for T x in h' yields the elements in STORAGE order (the
implicit tree's array), not sorted order — pop repeatedly for sorted
order. Do not mutate the heap while iterating.

Traps (container convention, like the built-in list): pop and peek on
an empty heap print what trapped and a stack trace, then exit(1).

Generic calls need explicit type arguments (heap_push[int](h, 5)):
inference cannot see through the heap[T]* parameter shape
(docs/projects/generics.md).
*/
import lib.lib
import lib.stack_trace


type heap_compare = fn(int, int) -> int


struct heap[T]:
	int capacity
	int length
	heap_compare* compare
	T* items


void heap_trap(char* message):
	println2(message)
	print_stack_trace()
	exit(1)


heap[T]* heap_new_sized[T](int capacity):
	if (capacity < 4):
		capacity = 4
	# four word-sized fields on every instantiation (payload policy)
	heap[T]* h = cast(heap[T]*, malloc(4 * __word_size__))
	h.capacity = capacity
	h.length = 0
	h.compare = cast(heap_compare*, 0)
	h.items = cast(T*, malloc(capacity * __word_size__))
	return h


heap[T]* heap_new[T]():
	return heap_new_sized[T](8)


# Min-heap under a caller-provided ordering: compare(a, b) returns
# negative/zero/positive like strcmp (the list.sort_by contract), so
# pop yields the element compare orders first. A reversed comparator
# makes a max-heap.
heap[T]* heap_new_by[T](heap_compare* compare):
	heap[T]* h = heap_new_sized[T](8)
	h.compare = compare
	return h


int heap_less[T](heap[T]* h, T a, T b):
	heap_compare* compare = h.compare
	if (cast(int, compare) == 0):
		return cast(int, a) < cast(int, b)
	return compare(cast(int, a), cast(int, b)) < 0


void heap_ensure[T](heap[T]* h, int extra):
	int needed = h.length + extra
	if (needed > h.capacity):
		int new_capacity = h.capacity * 2
		if (new_capacity < needed):
			new_capacity = needed
		h.items = cast(T*, realloc(cast(void*, h.items), h.capacity * __word_size__, new_capacity * __word_size__))
		h.capacity = new_capacity


void heap_sift_up[T](heap[T]* h, int i):
	while (i > 0):
		int parent = (i - 1) / 2
		if (heap_less[T](h, h.items[i], h.items[parent]) == 0):
			return
		T swap = h.items[parent]
		h.items[parent] = h.items[i]
		h.items[i] = swap
		i = parent


void heap_sift_down[T](heap[T]* h, int i):
	while (1):
		int smallest = 2 * i + 1
		if (smallest >= h.length):
			return
		int right = smallest + 1
		if (right < h.length):
			if (heap_less[T](h, h.items[right], h.items[smallest])):
				smallest = right
		if (heap_less[T](h, h.items[smallest], h.items[i]) == 0):
			return
		T swap = h.items[i]
		h.items[i] = h.items[smallest]
		h.items[smallest] = swap
		i = smallest


void heap_push[T](heap[T]* h, T value):
	heap_ensure[T](h, 1)
	h.items[h.length] = value
	h.length = h.length + 1
	heap_sift_up[T](h, h.length - 1)


T heap_peek[T](heap[T]* h):
	if (h.length == 0):
		heap_trap(c"peek on empty heap")
	return h.items[0]


T heap_pop[T](heap[T]* h):
	if (h.length == 0):
		heap_trap(c"pop on empty heap")
	T top = h.items[0]
	h.length = h.length - 1
	if (h.length > 0):
		h.items[0] = h.items[h.length]
		heap_sift_down[T](h, 0)
	return top


int heap_length[T](heap[T]* h):
	return h.length


# Restore the heap invariant over the whole array in O(n) (bottom-up
# sift-down from the last parent).
void heap_heapify[T](heap[T]* h):
	int i = h.length / 2 - 1
	while (i >= 0):
		heap_sift_down[T](h, i)
		i = i - 1


# Build a heap from a built-in list's values in O(n); the list is not
# modified.
heap[T]* heap_from_list[T](list[T] values):
	heap[T]* h = heap_new_sized[T](values.length)
	int i = 0
	while (i < values.length):
		h.items[i] = values[i]
		i = i + 1
	h.length = values.length
	heap_heapify[T](h)
	return h


heap[T]* heap_from_list_by[T](list[T] values, heap_compare* compare):
	heap[T]* h = heap_new_sized[T](values.length)
	h.compare = compare
	int i = 0
	while (i < values.length):
		h.items[i] = values[i]
		i = i + 1
	h.length = values.length
	heap_heapify[T](h)
	return h


void heap_free[T](heap[T]* h):
	free(cast(void*, h.items))
	free(h)


# Cursor protocol (grammar/for_statement.w): storage-order iteration.
int heap_iter_begin[T](heap[T]* h):
	return 0


int heap_iter_done[T](heap[T]* h, int cursor):
	return cursor >= h.length


int heap_iter_next[T](heap[T]* h, int cursor):
	return cursor + 1


T heap_iter_value[T](heap[T]* h, int cursor):
	if (cursor >= h.length):
		heap_trap(c"heap iterator out of range")
	return h.items[cursor]
