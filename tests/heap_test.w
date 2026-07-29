# wbuild: x64
# structures/heap.w — generic binary min-heap: ordering, growth,
# comparators, heapify, cursor-protocol iteration, and the merge-k-
# sorted-lists pattern (issue #360).
import lib.testing
import structures.heap


int heap_test_desc(int a, int b):
	return b - a


int heap_test_cstr_cmp(int a, int b):
	return strcmp(cast(char*, a), cast(char*, b))


void test_push_pop_sorted():
	heap[int]* h = heap_new[int]()
	heap_push[int](h, 5)
	heap_push[int](h, 1)
	heap_push[int](h, 4)
	heap_push[int](h, 2)
	heap_push[int](h, 3)
	assert_equal(5, h.length)
	assert_equal(1, heap_pop[int](h))
	assert_equal(2, heap_pop[int](h))
	assert_equal(3, heap_pop[int](h))
	assert_equal(4, heap_pop[int](h))
	assert_equal(5, heap_pop[int](h))
	assert_equal(0, h.length)
	heap_free[int](h)


void test_peek_keeps_element():
	heap[int]* h = heap_new[int]()
	heap_push[int](h, 7)
	heap_push[int](h, 3)
	assert_equal(3, heap_peek[int](h))
	assert_equal(2, h.length)
	assert_equal(2, heap_length[int](h))
	assert_equal(3, heap_pop[int](h))
	heap_free[int](h)


void test_interleaved_push_pop():
	heap[int]* h = heap_new[int]()
	heap_push[int](h, 5)
	heap_push[int](h, 1)
	assert_equal(1, heap_pop[int](h))
	heap_push[int](h, 0)
	assert_equal(0, heap_pop[int](h))
	assert_equal(5, heap_pop[int](h))
	assert_equal(0, h.length)
	heap_free[int](h)


void test_duplicates_and_negatives():
	heap[int]* h = heap_new[int]()
	heap_push[int](h, 2)
	heap_push[int](h, -3)
	heap_push[int](h, 2)
	heap_push[int](h, -3)
	assert_equal(-3, heap_pop[int](h))
	assert_equal(-3, heap_pop[int](h))
	assert_equal(2, heap_pop[int](h))
	assert_equal(2, heap_pop[int](h))
	heap_free[int](h)


void test_growth_beyond_initial_capacity():
	heap[int]* h = heap_new_sized[int](4)
	for int i in range(100):
		heap_push[int](h, (i * 37) % 101)
	assert_equal(100, h.length)
	int previous = -1
	for int i in range(100):
		int value = heap_pop[int](h)
		asserts(c"heap pop order must be non-decreasing", previous <= value)
		previous = value
	assert_equal(0, h.length)
	heap_free[int](h)


void test_max_heap_via_comparator():
	heap[int]* h = heap_new_by[int](heap_test_desc)
	heap_push[int](h, 3)
	heap_push[int](h, 1)
	heap_push[int](h, 4)
	heap_push[int](h, 1)
	heap_push[int](h, 5)
	assert_equal(5, heap_pop[int](h))
	assert_equal(4, heap_pop[int](h))
	assert_equal(3, heap_pop[int](h))
	assert_equal(1, heap_pop[int](h))
	assert_equal(1, heap_pop[int](h))
	heap_free[int](h)


void test_cstr_contents_ordering():
	heap[char*]* h = heap_new_by[char*](heap_test_cstr_cmp)
	heap_push[char*](h, c"pear")
	heap_push[char*](h, c"apple")
	heap_push[char*](h, c"fig")
	assert_strings_equal(c"apple", heap_pop[char*](h))
	assert_strings_equal(c"fig", heap_pop[char*](h))
	assert_strings_equal(c"pear", heap_pop[char*](h))
	heap_free[char*](h)


void test_heap_from_list_heap_sort():
	list[int] values = list[int]{9, 3, 7, 1, 8, 2}
	heap[int]* h = heap_from_list[int](values)
	assert_equal(6, h.length)
	list[int] sorted = new list[int]
	while (h.length > 0):
		sorted.push(heap_pop[int](h))
	assert_equal(1, sorted[0])
	assert_equal(2, sorted[1])
	assert_equal(3, sorted[2])
	assert_equal(7, sorted[3])
	assert_equal(8, sorted[4])
	assert_equal(9, sorted[5])
	# the source list is untouched
	assert_equal(6, values.length)
	assert_equal(9, values[0])
	heap_free[int](h)


void test_heap_from_list_by():
	heap[int]* h = heap_from_list_by[int](list[int]{4, 6, 5}, heap_test_desc)
	assert_equal(6, heap_pop[int](h))
	assert_equal(5, heap_pop[int](h))
	assert_equal(4, heap_pop[int](h))
	heap_free[int](h)


void test_iteration_storage_order():
	heap[int]* h = heap_new[int]()
	for int v in list[int]{5, 1, 4, 2, 3}:
		heap_push[int](h, v)
	int sum = 0
	int count = 0
	for int x in h:
		sum = sum + x
		count = count + 1
	assert_equal(15, sum)
	assert_equal(5, count)
	# the minimum sits at the root whatever the storage order
	assert_equal(1, heap_iter_value[int](h, 0))
	heap_free[int](h)


void test_iteration_empty_and_break():
	heap[int]* h = heap_new[int]()
	int count = 0
	for int x in h:
		count = count + 1
	assert_equal(0, count)
	heap_push[int](h, 1)
	heap_push[int](h, 2)
	heap_push[int](h, 3)
	for int x in h:
		count = count + 1
		if (count == 2):
			break
	assert_equal(2, count)
	heap_free[int](h)


void test_iteration_inferred_variable():
	heap[char*]* h = heap_new_by[char*](heap_test_cstr_cmp)
	heap_push[char*](h, c"pear")
	heap_push[char*](h, c"apple")
	int letters = 0
	for s in h:
		letters = letters + strlen(s)
	assert_equal(9, letters)
	heap_free[char*](h)


# Merge k sorted lists (the classic heap payoff): a min-heap of list
# cursors ordered by each cursor's current value; pop the smallest,
# advance it, push it back until every cursor is exhausted.
struct hk_cursor:
	list[int] values
	int pos


hk_cursor* hk_cursor_new(list[int] values):
	hk_cursor* c = new hk_cursor()
	c.values = values
	c.pos = 0
	return c


int hk_cursor_min(int a, int b):
	hk_cursor* ca = cast(hk_cursor*, a)
	hk_cursor* cb = cast(hk_cursor*, b)
	return ca.values[ca.pos] - cb.values[cb.pos]


list[int] hk_merge(heap[hk_cursor*]* h):
	list[int] merged = new list[int]
	while (h.length > 0):
		hk_cursor* c = heap_pop[hk_cursor*](h)
		merged.push(c.values[c.pos])
		c.pos = c.pos + 1
		if (c.pos < c.values.length):
			heap_push[hk_cursor*](h, c)
	return merged


void test_merge_k_sorted_lists():
	heap[hk_cursor*]* h = heap_new_by[hk_cursor*](hk_cursor_min)
	heap_push[hk_cursor*](h, hk_cursor_new(list[int]{1, 4, 5}))
	heap_push[hk_cursor*](h, hk_cursor_new(list[int]{1, 3, 4}))
	heap_push[hk_cursor*](h, hk_cursor_new(list[int]{2, 6}))
	list[int] merged = hk_merge(h)
	assert_equal(8, merged.length)
	assert_equal(1, merged[0])
	assert_equal(1, merged[1])
	assert_equal(2, merged[2])
	assert_equal(3, merged[3])
	assert_equal(4, merged[4])
	assert_equal(4, merged[5])
	assert_equal(5, merged[6])
	assert_equal(6, merged[7])
	heap_free[hk_cursor*](h)
