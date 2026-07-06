import lib.testing
import libs.standard.collections.heapq


void assert_heap_invariant(list[int] heap):
	for int i in range(heap.length):
		int left = i * 2 + 1
		int right = left + 1
		if (left < heap.length):
			assert1(heap[i] <= heap[left])
		if (right < heap.length):
			assert1(heap[i] <= heap[right])


void test_heap_push_pop_sorted_order():
	list[int] heap = new list[int]
	heap_push(heap, 5)
	assert_heap_invariant(heap)
	heap_push(heap, 1)
	assert_heap_invariant(heap)
	heap_push(heap, 3)
	assert_heap_invariant(heap)
	heap_push(heap, 1)
	assert_heap_invariant(heap)
	heap_push(heap, -2)
	assert_heap_invariant(heap)
	assert_equal(-2, heap_pop(heap))
	assert_heap_invariant(heap)
	assert_equal(1, heap_pop(heap))
	assert_equal(1, heap_pop(heap))
	assert_equal(3, heap_pop(heap))
	assert_equal(5, heap_pop(heap))
	assert_equal(0, heap.length)


void test_heapify_existing_list():
	list[int] heap = list[int]{9, 4, 7, 1, 3, 1}
	heapify(heap)
	assert_heap_invariant(heap)
	assert_equal(1, heap_pop(heap))
	assert_equal(1, heap_pop(heap))
	assert_equal(3, heap_pop(heap))
	assert_equal(4, heap_pop(heap))
	assert_equal(7, heap_pop(heap))
	assert_equal(9, heap_pop(heap))
