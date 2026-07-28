# wbuild: x64
# structures/deque.w — generic ring-buffer deque: both ends, wraparound
# growth, indexing, cursor-protocol iteration, and the sliding-window-
# maximum pattern (issue #360).
import lib.testing
import structures.deque


void test_queue_fifo():
	deque[int]* d = deque_new[int]()
	deque_push_back[int](d, 1)
	deque_push_back[int](d, 2)
	deque_push_back[int](d, 3)
	assert_equal(3, d.length)
	assert_equal(1, deque_pop_front[int](d))
	assert_equal(2, deque_pop_front[int](d))
	assert_equal(3, deque_pop_front[int](d))
	assert_equal(0, d.length)
	deque_free[int](d)


void test_stack_lifo():
	deque[int]* d = deque_new[int]()
	deque_push_back[int](d, 1)
	deque_push_back[int](d, 2)
	deque_push_back[int](d, 3)
	assert_equal(3, deque_pop_back[int](d))
	assert_equal(2, deque_pop_back[int](d))
	assert_equal(1, deque_pop_back[int](d))
	deque_free[int](d)


void test_push_front():
	deque[int]* d = deque_new[int]()
	deque_push_front[int](d, 1)
	deque_push_front[int](d, 2)
	deque_push_front[int](d, 3)
	assert_equal(3, deque_pop_front[int](d))
	assert_equal(2, deque_pop_front[int](d))
	assert_equal(1, deque_pop_front[int](d))
	deque_free[int](d)


void test_mixed_ends_and_peeks():
	deque[int]* d = deque_new[int]()
	deque_push_back[int](d, 2)
	deque_push_front[int](d, 1)
	deque_push_back[int](d, 3)
	assert_equal(1, deque_peek_front[int](d))
	assert_equal(3, deque_peek_back[int](d))
	assert_equal(3, d.length)
	assert_equal(1, deque_pop_front[int](d))
	assert_equal(3, deque_pop_back[int](d))
	assert_equal(2, deque_pop_back[int](d))
	deque_free[int](d)


void test_wraparound_growth():
	# start at the minimum capacity (4), rotate the head off zero, then
	# force growth while the contents wrap the physical buffer
	deque[int]* d = deque_new_sized[int](4)
	deque_push_back[int](d, 1)
	deque_push_back[int](d, 2)
	deque_push_back[int](d, 3)
	deque_push_back[int](d, 4)
	assert_equal(1, deque_pop_front[int](d))
	assert_equal(2, deque_pop_front[int](d))
	deque_push_back[int](d, 5)
	deque_push_back[int](d, 6)
	deque_push_back[int](d, 7)
	deque_push_back[int](d, 8)
	assert_equal(6, d.length)
	for int i in range(6):
		assert_equal(i + 3, deque_get[int](d, i))
	for int i in range(6):
		assert_equal(i + 3, deque_pop_front[int](d))
	deque_free[int](d)


void test_growth_from_front_pushes():
	deque[int]* d = deque_new_sized[int](4)
	for int i in range(50):
		deque_push_front[int](d, i)
	assert_equal(50, d.length)
	for int i in range(50):
		assert_equal(49 - i, deque_pop_front[int](d))
	deque_free[int](d)


void test_index_get_set():
	deque[int]* d = deque_new[int]()
	deque_push_back[int](d, 10)
	deque_push_back[int](d, 20)
	deque_push_back[int](d, 30)
	assert_equal(10, deque_get[int](d, 0))
	assert_equal(30, deque_get[int](d, 2))
	deque_set[int](d, 1, 99)
	assert_equal(99, deque_get[int](d, 1))
	assert_equal(3, deque_length[int](d))
	deque_free[int](d)


void test_clear_and_reuse():
	deque[int]* d = deque_new[int]()
	deque_push_back[int](d, 1)
	deque_push_back[int](d, 2)
	deque_clear[int](d)
	assert_equal(0, d.length)
	deque_push_back[int](d, 7)
	assert_equal(7, deque_peek_front[int](d))
	assert_equal(7, deque_peek_back[int](d))
	deque_free[int](d)


void test_iteration_front_to_back():
	deque[int]* d = deque_new_sized[int](4)
	deque_push_back[int](d, 3)
	deque_push_back[int](d, 4)
	deque_push_front[int](d, 2)
	deque_push_front[int](d, 1)
	int digits = 0
	int count = 0
	for int x in d:
		digits = digits * 10 + x
		count = count + 1
	assert_equal(1234, digits)
	assert_equal(4, count)
	deque_free[int](d)


void test_iteration_empty_break_continue():
	deque[int]* d = deque_new[int]()
	int count = 0
	for int x in d:
		count = count + 1
	assert_equal(0, count)
	for int i in range(6):
		deque_push_back[int](d, i)
	int sum = 0
	for int x in d:
		if (x == 5):
			break
		if (x % 2):
			continue
		sum = sum + x
	assert_equal(6, sum) /* 0 + 2 + 4 */
	deque_free[int](d)


void test_iteration_inferred_variable():
	deque[char*]* d = deque_new[char*]()
	deque_push_back[char*](d, c"cherry")
	deque_push_front[char*](d, c"fig")
	int letters = 0
	for s in d:
		letters = letters + strlen(s)
	assert_equal(9, letters)
	assert_strings_equal(c"fig", deque_pop_front[char*](d))
	assert_strings_equal(c"cherry", deque_pop_back[char*](d))
	deque_free[char*](d)


# Sliding window maximum (the classic deque payoff): keep a deque of
# indices whose values decrease front to back; the front is the
# window's maximum.
list[int] swm(list[int] nums, int k):
	list[int] result = new list[int]
	deque[int]* window = deque_new[int]()
	int i = 0
	while (i < nums.length):
		if (window.length > 0):
			if (deque_peek_front[int](window) <= i - k):
				deque_pop_front[int](window)
		while (window.length > 0):
			if (nums[deque_peek_back[int](window)] >= nums[i]):
				break
			deque_pop_back[int](window)
		deque_push_back[int](window, i)
		if (i >= k - 1):
			result.push(nums[deque_peek_front[int](window)])
		i = i + 1
	deque_free[int](window)
	return result


void test_sliding_window_maximum():
	list[int] nums = list[int]{1, 3, -1, -3, 5, 3, 6, 7}
	list[int] maxima = swm(nums, 3)
	assert_equal(6, maxima.length)
	assert_equal(3, maxima[0])
	assert_equal(3, maxima[1])
	assert_equal(5, maxima[2])
	assert_equal(5, maxima[3])
	assert_equal(6, maxima[4])
	assert_equal(7, maxima[5])


void test_sliding_window_maximum_window_one():
	list[int] nums = list[int]{4, 2, 9}
	list[int] maxima = swm(nums, 1)
	assert_equal(3, maxima.length)
	assert_equal(4, maxima[0])
	assert_equal(2, maxima[1])
	assert_equal(9, maxima[2])
