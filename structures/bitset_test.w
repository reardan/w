# wbuild: x64
import lib.testing
import structures.bitset


void test_new_bitset_is_empty():
	bitset* b = bitset_new(100)
	assert_equal(100, b.size)
	assert_equal(4, b.words)
	assert_equal(0, bitset_count(b))
	assert_equal(0, bitset_get(b, 0))
	assert_equal(0, bitset_get(b, 99))
	assert_equal(-1, bitset_next_set_bit(b, 0))
	bitset_free(b)


void test_set_get_clear_toggle():
	bitset* b = bitset_new(70)
	# word 0, word boundary bits 31/32, word 2
	bitset_set(b, 0)
	bitset_set(b, 31)
	bitset_set(b, 32)
	bitset_set(b, 69)
	assert_equal(1, bitset_get(b, 0))
	assert_equal(1, bitset_get(b, 31))
	assert_equal(1, bitset_get(b, 32))
	assert_equal(1, bitset_get(b, 69))
	assert_equal(0, bitset_get(b, 1))
	assert_equal(0, bitset_get(b, 30))
	assert_equal(0, bitset_get(b, 33))
	assert_equal(4, bitset_count(b))
	# setting an already-set bit is idempotent
	bitset_set(b, 31)
	assert_equal(4, bitset_count(b))
	bitset_clear(b, 31)
	assert_equal(0, bitset_get(b, 31))
	assert_equal(1, bitset_get(b, 32))
	assert_equal(3, bitset_count(b))
	# clearing a clear bit is idempotent
	bitset_clear(b, 31)
	assert_equal(3, bitset_count(b))
	bitset_toggle(b, 31)
	assert_equal(1, bitset_get(b, 31))
	bitset_toggle(b, 31)
	assert_equal(0, bitset_get(b, 31))
	bitset_toggle(b, 0)
	assert_equal(0, bitset_get(b, 0))
	assert_equal(2, bitset_count(b))
	bitset_free(b)


void test_word_wise_operations():
	bitset* a = bitset_new(64)
	bitset* b = bitset_new(64)
	bitset_set(a, 0)
	bitset_set(a, 31)
	bitset_set(a, 40)
	bitset_set(b, 31)
	bitset_set(b, 40)
	bitset_set(b, 63)

	bitset* x = bitset_new(64)
	bitset_or(x, a)
	bitset_and(x, b)          # x = a & b
	assert_equal(2, bitset_count(x))
	assert_equal(1, bitset_get(x, 31))
	assert_equal(1, bitset_get(x, 40))
	assert_equal(0, bitset_get(x, 0))
	assert_equal(0, bitset_get(x, 63))

	bitset_or(x, a)
	bitset_or(x, b)           # x = a | b
	assert_equal(4, bitset_count(x))
	assert_equal(1, bitset_get(x, 0))
	assert_equal(1, bitset_get(x, 63))

	bitset_xor(x, x)          # anything ^ itself is empty
	assert_equal(0, bitset_count(x))
	bitset_or(x, a)
	bitset_xor(x, b)          # x = a ^ b
	assert_equal(2, bitset_count(x))
	assert_equal(1, bitset_get(x, 0))
	assert_equal(1, bitset_get(x, 63))
	assert_equal(0, bitset_get(x, 31))
	assert_equal(0, bitset_get(x, 40))

	bitset_xor(x, x)
	bitset_or(x, a)
	bitset_andnot(x, b)       # x = a & ~b
	assert_equal(1, bitset_count(x))
	assert_equal(1, bitset_get(x, 0))
	assert_equal(0, bitset_get(x, 31))
	assert_equal(0, bitset_get(x, 40))

	bitset_free(x)
	bitset_free(b)
	bitset_free(a)


void test_count_full_words():
	bitset* b = bitset_new(96)
	int i = 0
	while (i < 96):
		bitset_set(b, i)
		i = i + 1
	assert_equal(96, bitset_count(b))
	bitset_clear(b, 32)
	assert_equal(95, bitset_count(b))
	bitset_free(b)


void test_next_set_bit_iteration():
	bitset* b = bitset_new(200)
	bitset_set(b, 3)
	bitset_set(b, 31)
	bitset_set(b, 32)
	bitset_set(b, 130)
	bitset_set(b, 199)
	assert_equal(3, bitset_next_set_bit(b, 0))
	assert_equal(3, bitset_next_set_bit(b, 3))
	assert_equal(31, bitset_next_set_bit(b, 4))
	assert_equal(32, bitset_next_set_bit(b, 32))
	assert_equal(130, bitset_next_set_bit(b, 33))
	assert_equal(199, bitset_next_set_bit(b, 131))
	assert_equal(-1, bitset_next_set_bit(b, 200))
	# a negative 'from' starts at 0
	assert_equal(3, bitset_next_set_bit(b, -7))
	# the documented iteration pattern visits every set bit once
	int visited = 0
	int i = bitset_next_set_bit(b, 0)
	while (i >= 0):
		visited = visited + 1
		i = bitset_next_set_bit(b, i + 1)
	assert_equal(5, visited)
	bitset_free(b)


void test_serialize_round_trip():
	bitset* b = bitset_new(77)
	bitset_set(b, 0)
	bitset_set(b, 31)   # bit 31 exercises the word's sign position
	bitset_set(b, 32)
	bitset_set(b, 76)
	int n = bitset_serialized_size(b)
	assert_equal(4 + 3 * 4, n)
	char* buffer = malloc(n)
	bitset_serialize(b, buffer)
	bitset* copy = bitset_deserialize(buffer)
	assert_equal(b.size, copy.size)
	assert_equal(b.words, copy.words)
	assert_equal(bitset_count(b), bitset_count(copy))
	int i = 0
	while (i < b.size):
		assert_equal(bitset_get(b, i), bitset_get(copy, i))
		i = i + 1
	bitset_free(copy)
	free(buffer)
	bitset_free(b)


void test_serialize_empty_bitset():
	bitset* b = bitset_new(0)
	assert_equal(0, bitset_count(b))
	assert_equal(-1, bitset_next_set_bit(b, 0))
	assert_equal(4, bitset_serialized_size(b))
	char* buffer = malloc(4)
	bitset_serialize(b, buffer)
	bitset* copy = bitset_deserialize(buffer)
	assert_equal(0, copy.size)
	assert_equal(0, bitset_count(copy))
	bitset_free(copy)
	free(buffer)
	bitset_free(b)


void test_binary_literals_compose_with_bitset():
	# 0b literals (#249 stage 1) describing bit indexes
	bitset* b = bitset_new(0b100000)
	assert_equal(32, b.size)
	bitset_set(b, 0b101)
	assert_equal(1, bitset_get(b, 5))
	assert_equal(5, bitset_next_set_bit(b, 0))
	bitset_free(b)
