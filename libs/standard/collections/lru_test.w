# wbuild: x64
# wbuild: step="bin/lru_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import libs.standard.collections.lru


# Drop log: "<key or int>=<value>" entries joined by spaces.
struct lru_test_log:
	char* text
	int drops


char* lru_test_concat(char* a, char* b):
	int la = strlen(a)
	int lb = strlen(b)
	char* out = cast(char*, malloc(la + lb + 1))
	for i in range(la): out[i] = a[i]
	for i in range(lb): out[la + i] = b[i]
	out[la + lb] = 0
	return out


void lru_test_append(lru_test_log* log, char* piece):
	char* next = lru_test_concat(log.text, piece)
	free(log.text)
	log.text = next


void lru_test_on_drop(void* context, char* key, int int_key, int value):
	lru_test_log* log = cast(lru_test_log*, context)
	if (log.drops > 0): lru_test_append(log, c" ")
	if (key != 0): lru_test_append(log, key)
	else:
		char* k = itoa(int_key)
		lru_test_append(log, k)
		free(k)
	lru_test_append(log, c"=")
	char* v = itoa(value)
	lru_test_append(log, v)
	free(v)
	log.drops = log.drops + 1


lru_test_log* lru_test_log_new():
	lru_test_log* log = new lru_test_log()
	log.text = strclone(c"")
	log.drops = 0
	return log


void lru_test_log_free(lru_test_log* log):
	free(log.text)
	free(log)


# Keys least -> most recently used, space-joined.
void assert_lru_order(char* want, lru_cache* c):
	list[char*] keys = lru_keys(c)
	char* text = strclone(c"")
	for i in range(keys.length):
		if (i > 0):
			char* t = lru_test_concat(text, c" ")
			free(text)
			text = t
		char* t2 = lru_test_concat(text, keys[i])
		free(text)
		text = t2
	assert_strings_equal(want, text)
	assert_equal(c.length, keys.length)
	free(text)
	keys.free()


void test_lru_basic_get_put():
	lru_cache* c = lru_new(2)
	assert_equal(0, c.length)
	assert_equal(-1, lru_get(c, c"a", -1))
	assert_equal(1, c.misses)
	lru_put(c, c"a", 1)
	lru_put(c, c"b", 2)
	assert_equal(1, lru_get(c, c"a", -1))
	assert_equal(2, lru_get(c, c"b", -1))
	assert_equal(2, c.hits)
	assert_equal(1, c.misses)
	assert_equal(2, c.length)
	int out = 0
	assert1(lru_lookup(c, c"a", &out))
	assert_equal(1, out)
	assert1(!lru_lookup(c, c"zz", &out))
	assert_equal(1, out)
	assert1(lru_lookup(c, c"b", 0))
	assert_equal(4, c.hits)
	assert_equal(2, c.misses)
	lru_free(c)


void test_lru_eviction_order():
	lru_test_log* log = lru_test_log_new()
	lru_cache* c = lru_new(3)
	lru_set_on_drop(c, lru_test_on_drop, cast(void*, log))
	lru_put(c, c"a", 1)
	lru_put(c, c"b", 2)
	lru_put(c, c"c", 3)
	assert_lru_order(c"a b c", c)
	# Touch a: b becomes least recent.
	lru_get(c, c"a", 0)
	assert_lru_order(c"b c a", c)
	lru_put(c, c"d", 4)
	assert_strings_equal(c"b=2", log.text)
	assert_lru_order(c"c a d", c)
	assert1(!lru_contains(c, c"b"))
	# Re-putting an existing key refreshes it.
	lru_put(c, c"c", 3)
	assert_lru_order(c"a d c", c)
	lru_put(c, c"e", 5)
	lru_put(c, c"f", 6)
	assert_strings_equal(c"b=2 a=1 d=4", log.text)
	assert_lru_order(c"c e f", c)
	assert_equal(3, c.evictions)
	assert_equal(3, c.length)
	lru_free(c)
	# Free drops the rest, oldest first.
	assert_strings_equal(c"b=2 a=1 d=4 c=3 e=5 f=6", log.text)
	lru_test_log_free(log)


void test_lru_peek_and_contains_do_not_touch():
	lru_cache* c = lru_new(2)
	lru_put(c, c"a", 1)
	lru_put(c, c"b", 2)
	assert_equal(1, lru_peek(c, c"a", 0))
	assert_equal(7, lru_peek(c, c"zz", 7))
	assert1(lru_contains(c, c"a"))
	assert_equal(0, c.hits)
	assert_equal(0, c.misses)
	lru_put(c, c"c", 3)
	# a was only peeked, so it was still least recent.
	assert1(!lru_contains(c, c"a"))
	assert_lru_order(c"b c", c)
	lru_free(c)


void test_lru_replace_drops_old_value():
	lru_test_log* log = lru_test_log_new()
	lru_cache* c = lru_new(4)
	lru_set_on_drop(c, lru_test_on_drop, cast(void*, log))
	lru_put(c, c"k", 10)
	lru_put(c, c"k", 10)
	assert_equal(0, log.drops)
	lru_put(c, c"k", 11)
	assert_strings_equal(c"k=10", log.text)
	assert_equal(11, lru_get(c, c"k", 0))
	assert_equal(1, c.length)
	assert_equal(0, c.evictions)
	lru_free(c)
	assert_strings_equal(c"k=10 k=11", log.text)
	lru_test_log_free(log)


void test_lru_remove_pop_clear():
	lru_test_log* log = lru_test_log_new()
	lru_cache* c = lru_new(4)
	lru_set_on_drop(c, lru_test_on_drop, cast(void*, log))
	lru_put(c, c"a", 1)
	lru_put(c, c"b", 2)
	lru_put(c, c"c", 3)
	assert1(lru_remove(c, c"b"))
	assert1(!lru_remove(c, c"b"))
	assert_strings_equal(c"b=2", log.text)
	int out = 0
	assert1(lru_pop(c, c"a", &out))
	assert_equal(1, out)
	assert1(!lru_pop(c, c"a", &out))
	# pop hands the value back: no drop.
	assert_strings_equal(c"b=2", log.text)
	assert_lru_order(c"c", c)
	lru_get(c, c"c", 0)
	lru_get(c, c"x", 0)
	lru_put(c, c"d", 4)
	lru_clear(c)
	assert_strings_equal(c"b=2 c=3 d=4", log.text)
	assert_equal(0, c.length)
	assert_equal(0, c.hits)
	assert_equal(0, c.misses)
	assert_lru_order(c"", c)
	# Usable after clear.
	lru_put(c, c"e", 5)
	assert_equal(5, lru_get(c, c"e", 0))
	lru_free(c)
	lru_test_log_free(log)


void test_lru_owns_keys():
	lru_cache* c = lru_new(2)
	char* key = strclone(c"temp")
	lru_put(c, key, 9)
	key[0] = 'X'
	free(key)
	assert_equal(9, lru_get(c, c"temp", 0))
	lru_free(c)


void test_lru_capacity_one_and_zero():
	lru_cache* c = lru_new(1)
	lru_put(c, c"a", 1)
	lru_put(c, c"b", 2)
	assert_lru_order(c"b", c)
	assert_equal(1, c.evictions)
	lru_free(c)

	lru_test_log* log = lru_test_log_new()
	c = lru_new(0)
	lru_set_on_drop(c, lru_test_on_drop, cast(void*, log))
	lru_put(c, c"a", 1)
	assert_equal(0, c.length)
	assert_equal(0, lru_get(c, c"a", 0))
	assert_equal(1, c.misses)
	assert_strings_equal(c"a=1", log.text)
	lru_free(c)
	lru_test_log_free(log)


void test_lru_unbounded_and_resize():
	lru_test_log* log = lru_test_log_new()
	lru_cache* c = lru_int_new(-1)
	lru_set_on_drop(c, lru_test_on_drop, cast(void*, log))
	for i in range(1000): lru_put_int(c, i, i * 2)
	assert_equal(1000, c.length)
	assert_equal(0, c.evictions)
	assert_equal(1998, lru_get_int(c, 999, -1))
	# Touch 0 so it survives the shrink.
	assert_equal(0, lru_get_int(c, 0, -1))
	lru_resize(c, 3)
	assert_equal(3, c.length)
	assert_equal(997, c.evictions)
	list[int] keys = lru_int_keys(c)
	assert_equal(3, keys.length)
	assert_equal(998, keys[0])
	assert_equal(999, keys[1])
	assert_equal(0, keys[2])
	keys.free()
	assert_equal(997, log.drops)
	lru_free(c)
	lru_test_log_free(log)


void test_lru_int_keys():
	lru_test_log* log = lru_test_log_new()
	lru_cache* c = lru_int_new(2)
	lru_set_on_drop(c, lru_test_on_drop, cast(void*, log))
	lru_put_int(c, 0, 100)
	lru_put_int(c, -5, 200)
	assert_equal(100, lru_get_int(c, 0, -1))
	lru_put_int(c, 7, 300)
	assert_strings_equal(c"-5=200", log.text)
	assert1(!lru_contains_int(c, -5))
	assert1(lru_contains_int(c, 0))
	assert_equal(300, lru_peek_int(c, 7, -1))
	assert_equal(-1, lru_peek_int(c, -5, -1))
	int out = 0
	assert1(lru_lookup_int(c, 7, &out))
	assert_equal(300, out)
	assert1(lru_pop_int(c, 0, &out))
	assert_equal(100, out)
	assert1(!lru_remove_int(c, 0))
	assert1(lru_remove_int(c, 7))
	assert_strings_equal(c"-5=200 7=300", log.text)
	assert_equal(0, c.length)
	lru_free(c)
	lru_test_log_free(log)


# Values that own memory: the drop callback frees them.
void lru_test_free_value(void* context, char* key, int int_key, int value):
	free(cast(char*, value))


void test_lru_owned_values_are_freed():
	lru_cache* c = lru_new(2)
	lru_set_on_drop(c, lru_test_free_value, 0)
	lru_put(c, c"a", cast(int, strclone(c"alpha")))
	lru_put(c, c"b", cast(int, strclone(c"beta")))
	lru_put(c, c"a", cast(int, strclone(c"alpha2")))
	lru_put(c, c"c", cast(int, strclone(c"gamma")))
	assert_strings_equal(c"alpha2", cast(char*, lru_get(c, c"a", 0)))
	assert1(!lru_contains(c, c"b"))
	assert_strings_equal(c"gamma", cast(char*, lru_peek(c, c"c", 0)))
	lru_free(c)
