import lib.testing
import libs.standard.numeric.random


void test_random_u32_fixed_seed_sequence():
	random_state* state = random_new(cast(uint32, 1))
	assert_equal_hex(0x3c88596c, cast(int, random_u32(state)))
	assert_equal_hex(0x5e8885db, cast(int, random_u32(state)))


void test_random_range_is_deterministic_and_bounded():
	random_state* state = random_new(cast(uint32, 1))
	assert_equal(13, random_range(state, 5, 15))
	int i = 0
	while (i < 100):
		int value = random_range(state, -3, 4)
		assert1(value >= -3)
		assert1(value < 4)
		i = i + 1


void test_random_shuffle_keeps_values():
	random_state* state = random_new(cast(uint32, 7))
	int* values = malloc(5 * __word_size__)
	values[0] = 1
	values[1] = 2
	values[2] = 3
	values[3] = 4
	values[4] = 5
	random_shuffle(state, values, 5)
	int sum = 0
	int product = 1
	for int i in range(5):
		sum = sum + values[i]
		product = product * values[i]
	assert_equal(15, sum)
	assert_equal(120, product)
	free(values)
