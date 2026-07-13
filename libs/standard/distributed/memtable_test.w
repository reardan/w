# wbuild: x64
import lib.testing
import libs.standard.distributed.memtable


int* mt_len_out():
	return cast(int*, malloc(__word_size__))


char** mt_val_out():
	return cast(char**, malloc(__word_size__))


void test_empty():
	memtable* m = memtable_new()
	assert_equal(0, memtable_count(m))
	assert_equal(0, memtable_bytes(m))
	char** v = mt_val_out()
	int* n = mt_len_out()
	assert_equal(0, memtable_get(m, c"missing", v, n))
	memtable_free(m)
	free(cast(char*, v))
	free(n)


void test_put_get_replace():
	memtable* m = memtable_new()
	memtable_put(m, c"alpha", c"one", 3)
	memtable_put(m, c"beta", c"two", 3)
	char** v = mt_val_out()
	int* n = mt_len_out()
	assert_equal(1, memtable_get(m, c"alpha", v, n))
	assert_equal(3, n[0])
	assert_strings_equal(c"one", v[0])
	assert_equal(2, memtable_count(m))
	int before = memtable_bytes(m)
	assert_equal(5 + 3 + 4 + 3, before)
	# replace changes value and bytes, not count
	memtable_put(m, c"alpha", c"uno!!", 5)
	assert_equal(2, memtable_count(m))
	assert_equal(before + 2, memtable_bytes(m))
	assert_equal(1, memtable_get(m, c"alpha", v, n))
	assert_strings_equal(c"uno!!", v[0])
	memtable_free(m)
	free(cast(char*, v))
	free(n)


void test_sorted_order_and_iteration():
	memtable* m = memtable_new()
	memtable_put(m, c"delta", c"4", 1)
	memtable_put(m, c"alpha", c"1", 1)
	memtable_put(m, c"charlie", c"3", 1)
	memtable_put(m, c"bravo", c"2", 1)
	assert_equal(4, memtable_count(m))
	assert_strings_equal(c"alpha", memtable_key_at(m, 0))
	assert_strings_equal(c"bravo", memtable_key_at(m, 1))
	assert_strings_equal(c"charlie", memtable_key_at(m, 2))
	assert_strings_equal(c"delta", memtable_key_at(m, 3))
	int* n = mt_len_out()
	char* val = memtable_value_at(m, 1, n)
	assert_equal(1, n[0])
	assert_strings_equal(c"2", val)
	assert_equal(0, memtable_is_tombstone_at(m, 1))
	memtable_free(m)
	free(n)


void test_tombstones():
	memtable* m = memtable_new()
	memtable_put(m, c"key", c"value", 5)
	memtable_delete(m, c"key")
	char** v = mt_val_out()
	int* n = mt_len_out()
	assert_equal(2, memtable_get(m, c"key", v, n))
	assert_equal(1, memtable_count(m))
	assert_equal(1, memtable_is_tombstone_at(m, 0))
	# deleting an unknown key records a bare tombstone (shadows sstables)
	memtable_delete(m, c"ghost")
	assert_equal(2, memtable_get(m, c"ghost", v, n))
	assert_equal(2, memtable_count(m))
	# tombstone bytes: key only
	assert_equal(3 + 5, memtable_bytes(m))
	# put over a tombstone resurrects
	memtable_put(m, c"key", c"back", 4)
	assert_equal(1, memtable_get(m, c"key", v, n))
	assert_strings_equal(c"back", v[0])
	memtable_free(m)
	free(cast(char*, v))
	free(n)


void test_binary_values():
	memtable* m = memtable_new()
	char* blob = malloc(4)
	blob[0] = 7
	blob[1] = 0
	blob[2] = 255
	blob[3] = 128
	memtable_put(m, c"bin", blob, 4)
	char** v = mt_val_out()
	int* n = mt_len_out()
	assert_equal(1, memtable_get(m, c"bin", v, n))
	assert_equal(4, n[0])
	assert_equal(7, v[0][0] & 255)
	assert_equal(0, v[0][1] & 255)
	assert_equal(255, v[0][2] & 255)
	assert_equal(128, v[0][3] & 255)
	free(blob)
	memtable_free(m)
	free(cast(char*, v))
	free(n)


void test_clear():
	memtable* m = memtable_new()
	memtable_put(m, c"a", c"1", 1)
	memtable_delete(m, c"b")
	memtable_clear(m)
	assert_equal(0, memtable_count(m))
	assert_equal(0, memtable_bytes(m))
	char** v = mt_val_out()
	int* n = mt_len_out()
	assert_equal(0, memtable_get(m, c"a", v, n))
	memtable_put(m, c"a", c"again", 5)
	assert_equal(1, memtable_get(m, c"a", v, n))
	memtable_free(m)
	free(cast(char*, v))
	free(n)


void test_many_keys_stay_sorted():
	memtable* m = memtable_new()
	# insert key00..key99 in a scrambled order (stride 37 mod 100)
	int i = 0
	while (i < 100):
		int k = (i * 37) % 100
		char* tens = itoa(k / 10)
		char* ones = itoa(k % 10)
		char* a = strjoin(c"key", tens)
		char* key = strjoin(a, ones)
		memtable_put(m, key, key, strlen(key))
		free(key)
		free(a)
		free(ones)
		free(tens)
		i = i + 1
	assert_equal(100, memtable_count(m))
	i = 1
	while (i < 100):
		assert1(strcmp(memtable_key_at(m, i - 1), memtable_key_at(m, i)) < 0)
		i = i + 1
	memtable_free(m)
