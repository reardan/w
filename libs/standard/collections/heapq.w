import lib.lib


# Min-heap helpers for list[int].
#
# heap_pop exits on an empty heap, matching the existing list pop behavior.
# Arithmetic is limited to list indices; heaps larger than signed int index
# space are outside this module's supported range.

void heapq_swap(list[int] heap, int a, int b):
	int t = heap[a]
	heap[a] = heap[b]
	heap[b] = t


void heapq_sift_up(list[int] heap, int pos):
	while (pos > 0):
		int parent = (pos - 1) / 2
		if (heap[parent] <= heap[pos]):
			return
		heapq_swap(heap, parent, pos)
		pos = parent


void heapq_sift_down(list[int] heap, int pos):
	int length = heap.length
	while (1):
		int left = pos * 2 + 1
		if (left >= length):
			return
		int right = left + 1
		int child = left
		if (right < length):
			if (heap[right] < heap[left]):
				child = right
		if (heap[pos] <= heap[child]):
			return
		heapq_swap(heap, pos, child)
		pos = child


void heap_push(list[int] heap, int value):
	heap.push(value)
	heapq_sift_up(heap, heap.length - 1)


int heap_pop(list[int] heap):
	if (heap.length == 0):
		exit(1)
	int result = heap[0]
	int last = heap.pop()
	if (heap.length > 0):
		heap[0] = last
		heapq_sift_down(heap, 0)
	return result


void heapify(list[int] heap):
	int pos = heap.length / 2 - 1
	while (pos >= 0):
		heapq_sift_down(heap, pos)
		pos = pos - 1
