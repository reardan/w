# wbuild: x64
# wbuild: step="bin/counter_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import libs.standard.collections.counter


list[char*] counter_test_words(char* text):
	# Split on spaces into fresh copies (the caller frees them).
	list[char*] out = new list[char*]
	int start = 0
	int i = 0
	while (true):
		if (text[i] == ' ' || text[i] == 0):
			if (i > start):
				char* w = cast(char*, malloc(i - start + 1))
				for j in range(i - start): w[j] = text[start + j]
				w[i - start] = 0
				out.push(w)
			if (text[i] == 0): break
			start = i + 1
		i = i + 1
	return out


void counter_test_free_words(list[char*] words):
	for char* w in words: free(w)
	words.free()


counter* counter_test_from(char* text):
	list[char*] words = counter_test_words(text)
	counter* c = counter_from_list(words)
	counter_test_free_words(words)
	return c


void test_counter_from_list_and_get():
	counter* c = counter_test_from(c"a b a c b a")
	assert_equal(3, counter_get(c, c"a"))
	assert_equal(2, counter_get(c, c"b"))
	assert_equal(1, counter_get(c, c"c"))
	assert_equal(0, counter_get(c, c"zzz"))
	# A missing read does not insert.
	assert1(!(counter_contains(c, c"zzz")))
	assert_equal(3, counter_length(c))
	assert_equal(6, counter_total(c))
	counter_free(c)


void test_counter_owns_keys():
	counter* c = counter_new()
	char* key = strclone(c"temp")
	counter_add(c, key, 4)
	key[0] = 'X'
	free(key)
	assert_equal(4, counter_get(c, c"temp"))
	counter_free(c)


void test_counter_add_set_remove():
	counter* c = counter_new()
	assert_equal(1, counter_add(c, c"x", 1))
	assert_equal(6, counter_add(c, c"x", 5))
	assert_equal(-2, counter_add(c, c"y", -2))
	counter_set(c, c"z", 0)
	assert1(counter_contains(c, c"z"))
	assert_equal(3, counter_length(c))
	assert_equal(4, counter_total(c))
	assert1(counter_remove(c, c"x"))
	assert1(!(counter_remove(c, c"x")))
	assert_equal(0, counter_get(c, c"x"))
	counter_clear(c)
	assert_equal(0, counter_length(c))
	assert_equal(0, counter_total(c))
	counter_add(c, c"again", 1)
	assert_equal(1, counter_get(c, c"again"))
	counter_free(c)


void test_counter_most_common_order():
	# Python: Counter("abracadabra").most_common()
	# -> a:5, b:2, r:2, c:1, d:1 (ties in first-seen order)
	counter* c = counter_test_from(c"a b r a c a d a b r a")
	list[char*] top = counter_most_common(c, -1)
	assert_equal(5, top.length)
	assert_strings_equal(c"a", top[0])
	assert_strings_equal(c"b", top[1])
	assert_strings_equal(c"r", top[2])
	assert_strings_equal(c"c", top[3])
	assert_strings_equal(c"d", top[4])
	assert_equal(2, counter_get(c, top[2]))
	top.free()

	top = counter_most_common(c, 3)
	assert_equal(3, top.length)
	assert_strings_equal(c"a", top[0])
	assert_strings_equal(c"b", top[1])
	assert_strings_equal(c"r", top[2])
	top.free()

	top = counter_most_common(c, 0)
	assert_equal(0, top.length)
	top.free()

	top = counter_most_common(c, 99)
	assert_equal(5, top.length)
	top.free()
	counter_free(c)


void test_counter_most_common_ties_and_negatives():
	counter* c = counter_new()
	counter_add(c, c"neg", -3)
	counter_add(c, c"one", 1)
	counter_add(c, c"zero", 0)
	counter_add(c, c"two", 2)
	counter_add(c, c"one_b", 1)
	counter_add(c, c"two_b", 2)
	list[char*] top = counter_most_common(c, -1)
	assert_equal(6, top.length)
	assert_strings_equal(c"two", top[0])
	assert_strings_equal(c"two_b", top[1])
	assert_strings_equal(c"one", top[2])
	assert_strings_equal(c"one_b", top[3])
	assert_strings_equal(c"zero", top[4])
	assert_strings_equal(c"neg", top[5])
	top.free()
	counter_free(c)


void test_counter_most_common_many():
	# Enough keys to exercise several merge passes: key i gets i % 7.
	counter* c = counter_new()
	char* buf = cast(char*, malloc(8))
	for i in range(100):
		buf[0] = 'k'
		buf[1] = cast(char, '0' + i / 10)
		buf[2] = cast(char, '0' + i % 10)
		buf[3] = 0
		counter_add(c, buf, i % 7)
	free(buf)
	list[char*] top = counter_most_common(c, -1)
	assert_equal(100, top.length)
	assert_strings_equal(c"k06", top[0])
	assert_strings_equal(c"k13", top[1])
	for i in range(1, 100):
		int prev = counter_get(c, top[i - 1])
		int cur = counter_get(c, top[i])
		assert1(prev >= cur)
		if (prev == cur): assert1(strcmp(top[i - 1], top[i]) < 0)
	top.free()
	counter_free(c)


void test_counter_empty():
	counter* c = counter_new()
	list[char*] top = counter_most_common(c, -1)
	assert_equal(0, top.length)
	top.free()
	list[char*] items = counter_elements(c)
	assert_equal(0, items.length)
	items.free()
	assert_equal(0, counter_total(c))
	counter_free(c)


void test_counter_update_subtract():
	counter* c = counter_test_from(c"a b")
	list[char*] more = counter_test_words(c"a a c")
	counter_update(c, more)
	assert_equal(3, counter_get(c, c"a"))
	assert_equal(1, counter_get(c, c"c"))
	counter_subtract(c, more)
	counter_subtract(c, more)
	assert_equal(-1, counter_get(c, c"a"))
	assert_equal(1, counter_get(c, c"b"))
	assert_equal(-1, counter_get(c, c"c"))
	counter_test_free_words(more)

	counter* d = counter_test_from(c"a b b")
	counter_update_counter(c, d)
	assert_equal(0, counter_get(c, c"a"))
	assert_equal(3, counter_get(c, c"b"))
	counter_subtract_counter(c, d)
	counter_subtract_counter(c, d)
	assert_equal(-2, counter_get(c, c"a"))
	assert_equal(-1, counter_get(c, c"b"))
	assert1(counter_contains(c, c"c"))
	counter_free(d)
	counter_free(c)


void test_counter_elements():
	# Python: Counter(a=4, b=2, c=0, d=-2).elements() -> a a a a b b
	counter* c = counter_new()
	counter_add(c, c"a", 4)
	counter_add(c, c"b", 2)
	counter_add(c, c"c", 0)
	counter_add(c, c"d", -2)
	list[char*] items = counter_elements(c)
	assert_equal(6, items.length)
	for i in range(4): assert_strings_equal(c"a", items[i])
	assert_strings_equal(c"b", items[4])
	assert_strings_equal(c"b", items[5])
	items.free()
	counter_free(c)


counter* counter_test_pairs(char* k1, int n1, char* k2, int n2, char* k3, int n3):
	counter* c = counter_new()
	if (k1 != 0): counter_set(c, k1, n1)
	if (k2 != 0): counter_set(c, k2, n2)
	if (k3 != 0): counter_set(c, k3, n3)
	return c


void test_counter_arithmetic():
	# Python: c = Counter(a=3, b=1, d=-1); d = Counter(a=1, b=2, e=-4)
	counter* a = counter_test_pairs(c"a", 3, c"b", 1, c"d", -1)
	counter* b = counter_test_pairs(c"a", 1, c"b", 2, c"e", -4)

	# c + d == Counter({'a': 4, 'b': 3})
	counter* r = counter_plus(a, b)
	assert_equal(2, counter_length(r))
	assert_equal(4, counter_get(r, c"a"))
	assert_equal(3, counter_get(r, c"b"))
	counter_free(r)

	# c - d == Counter({'a': 2, 'e': 4})
	r = counter_minus(a, b)
	assert_equal(2, counter_length(r))
	assert_equal(2, counter_get(r, c"a"))
	assert_equal(4, counter_get(r, c"e"))
	list[char*] keys = counter_most_common(r, -1)
	assert_strings_equal(c"e", keys[0])
	assert_strings_equal(c"a", keys[1])
	keys.free()
	counter_free(r)

	# c | d == Counter({'a': 3, 'b': 2})
	r = counter_union(a, b)
	assert_equal(2, counter_length(r))
	assert_equal(3, counter_get(r, c"a"))
	assert_equal(2, counter_get(r, c"b"))
	counter_free(r)

	# c & d == Counter({'a': 1, 'b': 1})
	r = counter_intersection(a, b)
	assert_equal(2, counter_length(r))
	assert_equal(1, counter_get(r, c"a"))
	assert_equal(1, counter_get(r, c"b"))
	counter_free(r)

	# Inputs are unchanged.
	assert_equal(3, counter_get(a, c"a"))
	assert_equal(-4, counter_get(b, c"e"))
	counter_free(a)
	counter_free(b)


void test_counter_copy_and_equal():
	counter* a = counter_test_pairs(c"x", 2, c"y", 0, 0, 0)
	counter* b = counter_copy(a)
	assert1(counter_equal(a, b))
	counter_add(b, c"x", 1)
	assert1(!(counter_equal(a, b)))
	assert_equal(2, counter_get(a, c"x"))
	counter_add(b, c"x", -1)
	counter_remove(b, c"y")
	# Missing keys compare as zero (Python 3.10+).
	assert1(counter_equal(a, b))
	assert1(counter_equal(b, a))
	counter_free(a)
	counter_free(b)
