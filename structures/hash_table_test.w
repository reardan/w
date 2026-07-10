# wbuild: x64
import lib.testing
import structures.hash_table


void test_map_word_keys():
	__w_hash_table* m = __w_map_new(__w_hash_key_word(), __word_size__)
	__w_map_set(m, 1, 10)
	__w_map_set(m, 2, 20)
	assert_equal(10, __w_map_get(m, 1))
	assert_equal(20, __w_map_get(m, 2))
	assert_equal(1, __w_map_contains(m, 1))
	assert_equal(0, __w_map_contains(m, 3))
	assert_equal(2, __w_map_length(m))
	__w_map_free(m)


void test_map_overwrite():
	__w_hash_table* m = __w_map_new(__w_hash_key_word(), __word_size__)
	__w_map_set(m, 7, 70)
	__w_map_set(m, 7, 71)
	assert_equal(71, __w_map_get(m, 7))
	assert_equal(1, __w_map_length(m))
	__w_map_free(m)


void test_map_growth_and_iteration():
	__w_hash_table* m = __w_map_new(__w_hash_key_word(), __word_size__)
	int i = 0
	while (i < 200):
		__w_map_set(m, i, i * 3)
		i = i + 1
	assert_equal(200, __w_map_length(m))
	i = 0
	while (i < 200):
		assert_equal(i * 3, __w_map_get(m, i))
		i = i + 1

	int count = 0
	int sum = 0
	int cursor = __w_map_iter_begin(m)
	while (__w_map_iter_done(m, cursor) == 0):
		int key = __w_map_iter_key(m, cursor)
		sum = sum + __w_map_get(m, key)
		count = count + 1
		cursor = __w_map_iter_next(m, cursor)
	assert_equal(200, count)
	assert_equal(59700, sum)
	__w_map_free(m)


void test_map_remove_tombstone():
	__w_hash_table* m = __w_map_new(__w_hash_key_word(), __word_size__)
	__w_map_set(m, 1, 10)
	__w_map_set(m, 17, 170)
	assert_equal(1, __w_map_remove(m, 1))
	assert_equal(0, __w_map_contains(m, 1))
	assert_equal(1, __w_map_contains(m, 17))
	__w_map_set(m, 33, 330)
	assert_equal(330, __w_map_get(m, 33))
	assert_equal(2, __w_map_length(m))
	__w_map_free(m)


void test_cstr_key_is_cloned():
	__w_hash_table* m = __w_map_new(__w_hash_key_cstr(), __word_size__)
	char* key = strclone(c"mutable")
	__w_map_set(m, cast(int, key), 42)
	key[0] = 'X'
	assert_equal(42, __w_map_get(m, c"mutable"))
	free(key)
	__w_map_free(m)


void test_string_key_contents():
	__w_hash_table* m = __w_map_new(__w_hash_key_string(), __word_size__)
	string one = s"alpha"
	string two = s"alpha"
	string other = s"beta"
	__w_map_set(m, cast(int, one), 11)
	assert_equal(11, __w_map_get(m, cast(int, two)))
	assert_equal(0, __w_map_contains(m, cast(int, other)))
	__w_map_free(m)


void test_set_word_keys():
	__w_hash_table* s = __w_set_new(__w_hash_key_word())
	__w_set_add(s, 4)
	__w_set_add(s, 4)
	__w_set_add(s, 5)
	assert_equal(1, __w_set_contains(s, 4))
	assert_equal(1, __w_set_contains(s, 5))
	assert_equal(0, __w_set_contains(s, 6))
	assert_equal(2, __w_set_length(s))
	assert_equal(1, __w_set_remove(s, 4))
	assert_equal(0, __w_set_contains(s, 4))
	__w_set_free(s)
