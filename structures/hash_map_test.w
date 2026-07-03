import lib.testing
import structures.hash_map


void test_set_get():
	hash_map* m = hash_map_new()
	hash_map_set(m, "one", 1)
	hash_map_set(m, "two", 2)
	hash_map_set(m, "three", 3)
	assert_equal(1, hash_map_get(m, "one"))
	assert_equal(2, hash_map_get(m, "two"))
	assert_equal(3, hash_map_get(m, "three"))
	assert_equal(3, m.count)
	hash_map_free(m)


void test_missing_key():
	hash_map* m = hash_map_new()
	hash_map_set(m, "here", 5)
	assert_equal(0, hash_map_get(m, "gone"))
	assert_equal(-7, hash_map_get_default(m, "gone", -7))
	assert_equal(1, hash_map_contains(m, "here"))
	assert_equal(0, hash_map_contains(m, "gone"))
	hash_map_free(m)


void test_overwrite():
	hash_map* m = hash_map_new()
	hash_map_set(m, "key", 1)
	hash_map_set(m, "key", 2)
	assert_equal(2, hash_map_get(m, "key"))
	assert_equal(1, m.count)
	hash_map_free(m)


void test_key_is_cloned():
	hash_map* m = hash_map_new()
	char* key = strclone("mutable")
	hash_map_set(m, key, 42)
	key[0] = 'X'
	assert_equal(42, hash_map_get(m, "mutable"))
	free(key)
	hash_map_free(m)


void test_growth():
	hash_map* m = hash_map_new()
	int i = 0
	while (i < 200):
		char* key = itoa(i)
		hash_map_set(m, key, i * 10)
		free(key)
		i = i + 1
	assert_equal(200, m.count)
	i = 0
	while (i < 200):
		char* key = itoa(i)
		assert_equal(i * 10, hash_map_get(m, key))
		free(key)
		i = i + 1
	hash_map_free(m)


void test_iter_empty():
	hash_map* m = hash_map_new()
	int cursor = hash_map_iter_begin(m)
	assert_equal(1, hash_map_iter_done(m, cursor))
	hash_map_free(m)


void test_iter_keys():
	hash_map* m = hash_map_new()
	hash_map_set(m, "one", 1)
	hash_map_set(m, "two", 2)
	hash_map_set(m, "three", 3)

	int cursor = hash_map_iter_begin(m)
	int count = 0
	int sum = 0
	while (hash_map_iter_done(m, cursor) == 0):
		char* key = hash_map_iter_value(m, cursor)
		assert_equal(1, hash_map_contains(m, key))
		count = count + 1
		sum = sum + hash_map_get(m, key)
		cursor = hash_map_iter_next(m, cursor)

	assert_equal(3, count)
	assert_equal(6, sum)
	assert_equal(1, hash_map_iter_done(m, cursor))
	hash_map_free(m)


void test_iter_keys_after_growth():
	hash_map* m = hash_map_new()
	int i = 0
	while (i < 100):
		char* key = itoa(i)
		hash_map_set(m, key, i)
		free(key)
		i = i + 1

	int* seen = malloc(100 * 4)
	i = 0
	while (i < 100):
		seen[i] = 0
		i = i + 1

	int cursor = hash_map_iter_begin(m)
	int count = 0
	while (hash_map_iter_done(m, cursor) == 0):
		char* key = hash_map_iter_value(m, cursor)
		assert_equal(1, hash_map_contains(m, key))
		int value = hash_map_get(m, key)
		assert1(value >= 0)
		assert1(value < 100)
		assert_equal(0, seen[value])
		seen[value] = 1
		count = count + 1
		cursor = hash_map_iter_next(m, cursor)

	assert_equal(100, count)
	i = 0
	while (i < 100):
		assert_equal(1, seen[i])
		i = i + 1
	assert_equal(1, hash_map_iter_done(m, cursor))
	free(seen)
	hash_map_free(m)
