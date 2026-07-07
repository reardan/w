import lib.testing
import lib.bitmap


void test_new_bitmap_all_clear():
	bitmap* map = bitmap_new(64)
	assert_equal(0, bitmap_test(map, 0))
	assert_equal(0, bitmap_test(map, 63))
	assert_equal(0, bitmap_count_set(map))
	assert_equal((-1), bitmap_find_first_set(map))
	assert_equal(0, bitmap_find_first_zero(map))
	bitmap_free(map)


void test_set_test_clear():
	bitmap* map = bitmap_new(64)
	bitmap_set(map, 0)
	bitmap_set(map, 33)
	bitmap_set(map, 63)
	assert_equal(1, bitmap_test(map, 0))
	assert_equal(1, bitmap_test(map, 33))
	assert_equal(1, bitmap_test(map, 63))
	assert_equal(0, bitmap_test(map, 1))
	assert_equal(0, bitmap_test(map, 32))
	assert_equal(3, bitmap_count_set(map))
	bitmap_clear(map, 33)
	assert_equal(0, bitmap_test(map, 33))
	assert_equal(2, bitmap_count_set(map))
	# Clearing a clear bit and re-clearing are no-ops.
	bitmap_clear(map, 33)
	bitmap_clear(map, 7)
	assert_equal(2, bitmap_count_set(map))
	bitmap_free(map)


void test_grows_on_demand():
	bitmap* map = bitmap_new(8)
	bitmap_set(map, 500)
	assert_equal(1, bitmap_test(map, 500))
	assert_equal(0, bitmap_test(map, 499))
	assert_equal(0, bitmap_test(map, 501))
	assert_equal(1, bitmap_count_set(map))
	# Out-of-range test/clear are safe no-ops.
	assert_equal(0, bitmap_test(map, 100000))
	bitmap_clear(map, 100000)
	bitmap_free(map)


void test_word_find_first_set():
	assert_equal(0, word_find_first_set(1))
	assert_equal(1, word_find_first_set(2))
	assert_equal(4, word_find_first_set(16))
	assert_equal(0, word_find_first_set(5))
	# The word-width top bit (sign bit) must work too.
	assert_equal(bits_per_word() - 1, word_find_first_set(1 << (bits_per_word() - 1)))


void test_find_next_set():
	bitmap* map = bitmap_new(256)
	bitmap_set(map, 3)
	bitmap_set(map, 64)
	bitmap_set(map, 200)
	assert_equal(3, bitmap_find_first_set(map))
	assert_equal(3, bitmap_find_next_set(map, 3))
	assert_equal(64, bitmap_find_next_set(map, 4))
	assert_equal(200, bitmap_find_next_set(map, 65))
	assert_equal((-1), bitmap_find_next_set(map, 201))
	bitmap_free(map)


void test_find_next_zero():
	bitmap* map = bitmap_new(bits_per_word())
	int i = 0
	while (i < bits_per_word()):
		bitmap_set(map, i)
		i = i + 1
	# Every in-range bit is set; the next zero is just past the words,
	# because the map is conceptually infinite.
	assert_equal(bits_per_word(), bitmap_find_first_zero(map))
	bitmap_clear(map, 5)
	assert_equal(5, bitmap_find_first_zero(map))
	assert_equal(bits_per_word(), bitmap_find_next_zero(map, 6))
	bitmap_free(map)


void test_dense_pattern():
	# Set every third bit across several words; verify exact recovery.
	bitmap* map = bitmap_new(300)
	int i = 0
	while (i < 300):
		bitmap_set(map, i * 3)
		i = i + 1
	assert_equal(300, bitmap_count_set(map))
	i = 0
	int bit = bitmap_find_first_set(map)
	while (bit != (-1)):
		assert_equal(i * 3, bit)
		i = i + 1
		bit = bitmap_find_next_set(map, bit + 1)
	assert_equal(300, i)
	bitmap_free(map)


void test_ida_alloc_lowest_free():
	ida* allocator = ida_new()
	assert_equal(0, ida_alloc(allocator))
	assert_equal(1, ida_alloc(allocator))
	assert_equal(2, ida_alloc(allocator))
	ida_free(allocator, 1)
	# Freed id is reused before extending the range.
	assert_equal(1, ida_alloc(allocator))
	assert_equal(3, ida_alloc(allocator))
	ida_free_all(allocator)


void test_ida_reuse_and_growth():
	ida* allocator = ida_new()
	int i = 0
	while (i < 200):
		assert_equal(i, ida_alloc(allocator))
		i = i + 1
	assert_equal(1, ida_is_allocated(allocator, 0))
	assert_equal(1, ida_is_allocated(allocator, 199))
	assert_equal(0, ida_is_allocated(allocator, 200))
	ida_free(allocator, 50)
	ida_free(allocator, 150)
	assert_equal(50, ida_alloc(allocator))
	assert_equal(150, ida_alloc(allocator))
	assert_equal(200, ida_alloc(allocator))
	ida_free_all(allocator)
