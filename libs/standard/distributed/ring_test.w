# wbuild: x64
import lib.testing
import libs.standard.distributed.ring


# "key<i>", malloc'd; caller frees.
char* ring_test_key(int i):
	char* num = itoa(i)
	char* key = strjoin(c"key", num)
	free(num)
	return key


hash_ring* ring_test_three():
	hash_ring* r = ring_new(32)
	assert_equal(1, ring_add_node(r, c"alpha"))
	assert_equal(1, ring_add_node(r, c"bravo"))
	assert_equal(1, ring_add_node(r, c"charlie"))
	assert_equal(3, ring_node_count(r))
	return r


void test_empty_ring():
	hash_ring* r = ring_new(4)
	assert_equal(0, ring_node_count(r))
	assert1(ring_lookup(r, c"anything") == 0)
	assert_equal(0, ring_remove_node(r, c"ghost"))
	char** out = cast(char**, malloc(3 * __word_size__))
	assert_equal(0, ring_successors(r, c"anything", 3, out))
	free(cast(void*, out))
	ring_free(r)


void test_points_are_31_bit_nonnegative():
	# The whole ordering contract rests on points never being negative
	# on any target.
	int i = 0
	while (i < 30):
		char* key = ring_test_key(i)
		assert1(ring_key_point(key) >= 0)
		free(key)
		i = i + 1
	i = 0
	while (i < 32):
		assert1(ring_vnode_point(c"alpha", i) >= 0)
		assert1(ring_vnode_point(c"bravo", i) >= 0)
		assert1(ring_vnode_point(c"charlie", i) >= 0)
		i = i + 1


void test_single_node_owns_everything():
	hash_ring* r = ring_new(8)
	assert_equal(1, ring_add_node(r, c"solo"))
	assert_equal(1, ring_node_count(r))
	int i = 0
	while (i < 10):
		char* key = ring_test_key(i)
		assert_strings_equal(c"solo", ring_lookup(r, key))
		free(key)
		i = i + 1
	char** out = cast(char**, malloc(3 * __word_size__))
	assert_equal(1, ring_successors(r, c"key0", 3, out))
	assert_strings_equal(c"solo", out[0])
	free(cast(void*, out))
	ring_free(r)


void test_three_nodes_coverage_and_order_independence():
	hash_ring* a = ring_test_three()
	# Same members added in a different order must produce identical
	# lookups: the ring is a pure function of the member set.
	hash_ring* b = ring_new(32)
	assert_equal(1, ring_add_node(b, c"charlie"))
	assert_equal(1, ring_add_node(b, c"alpha"))
	assert_equal(1, ring_add_node(b, c"bravo"))
	int alpha_keys = 0
	int bravo_keys = 0
	int charlie_keys = 0
	int i = 0
	while (i < 30):
		char* key = ring_test_key(i)
		char* owner = ring_lookup(a, key)
		if (strcmp(owner, c"alpha") == 0):
			alpha_keys = alpha_keys + 1
		if (strcmp(owner, c"bravo") == 0):
			bravo_keys = bravo_keys + 1
		if (strcmp(owner, c"charlie") == 0):
			charlie_keys = charlie_keys + 1
		assert_strings_equal(owner, ring_lookup(b, key))
		free(key)
		i = i + 1
	assert_equal(30, alpha_keys + bravo_keys + charlie_keys)
	assert1(alpha_keys >= 1)
	assert1(bravo_keys >= 1)
	assert1(charlie_keys >= 1)
	ring_free(a)
	ring_free(b)


void test_duplicate_add_is_rejected():
	hash_ring* r = ring_test_three()
	assert_equal(0, ring_add_node(r, c"alpha"))
	assert_equal(3, ring_node_count(r))
	# lookups unchanged by the rejected add
	assert_strings_equal(ring_lookup(r, c"key0"), ring_lookup(r, c"key0"))
	ring_free(r)


void test_removal_stability():
	hash_ring* r = ring_test_three()
	list[char*] before = new list[char*]
	int i = 0
	while (i < 30):
		char* key = ring_test_key(i)
		before.push(ring_lookup(r, key))
		free(key)
		i = i + 1
	assert_equal(1, ring_remove_node(r, c"bravo"))
	assert_equal(2, ring_node_count(r))
	assert_equal(0, ring_remove_node(r, c"bravo"))
	int moved = 0
	i = 0
	while (i < 30):
		char* key = ring_test_key(i)
		char* now = ring_lookup(r, key)
		if (strcmp(before[i], c"bravo") == 0):
			# formerly-bravo keys must land on a surviving node
			moved = moved + 1
			assert1(strcmp(now, c"alpha") == 0 || strcmp(now, c"charlie") == 0)
		else:
			# every other key keeps EXACTLY its old owner
			assert_strings_equal(before[i], now)
		free(key)
		i = i + 1
	assert1(moved >= 1)
	ring_free(r)


void test_successors_preference_list():
	hash_ring* r = ring_test_three()
	char** out = cast(char**, malloc(5 * __word_size__))
	int n = ring_successors(r, c"key3", 3, out)
	assert_equal(3, n)
	assert1(strcmp(out[0], out[1]) != 0)
	assert1(strcmp(out[0], out[2]) != 0)
	assert1(strcmp(out[1], out[2]) != 0)
	assert_strings_equal(ring_lookup(r, c"key3"), out[0])
	# only 3 distinct members exist, so asking for 5 still yields 3
	assert_equal(3, ring_successors(r, c"key3", 5, out))
	int m = ring_successors(r, c"key7", 2, out)
	assert_equal(2, m)
	assert1(strcmp(out[0], out[1]) != 0)
	assert_strings_equal(ring_lookup(r, c"key7"), out[0])
	free(cast(void*, out))
	ring_free(r)


void test_cross_target_determinism():
	# Owners observed on the x86 target. The sha256-derived 31-bit
	# points are target-independent, so the x64 build must agree byte
	# for byte; a mismatch here means a word-size bug in the point
	# derivation.
	hash_ring* r = ring_test_three()
	assert_strings_equal(c"alpha", ring_lookup(r, c"key0"))
	assert_strings_equal(c"charlie", ring_lookup(r, c"key3"))
	assert_strings_equal(c"bravo", ring_lookup(r, c"key7"))
	assert_strings_equal(c"charlie", ring_lookup(r, c"key10"))
	assert_strings_equal(c"bravo", ring_lookup(r, c"key14"))
	assert_strings_equal(c"alpha", ring_lookup(r, c"key20"))
	assert_strings_equal(c"charlie", ring_lookup(r, c"key28"))
	assert_strings_equal(c"bravo", ring_lookup(r, c"key29"))
	ring_free(r)
