# wbuild: x64
import lib.testing
import libs.standard.distributed.bloom


# "key<i>", malloc'd; caller frees.
char* bloom_test_key(int i):
	char* num = itoa(i)
	char* key = strjoin(c"key", num)
	free(num)
	return key


# "other<i>", malloc'd; caller frees.
char* bloom_test_other(int i):
	char* num = itoa(i)
	char* key = strjoin(c"other", num)
	free(num)
	return key


# The shared fixture: m=4096 bits, k=5 probes, key0..key49 added.
bloom_filter* bloom_test_loaded():
	bloom_filter* b = bloom_new(4096, 5)
	int i = 0
	while (i < 50):
		char* key = bloom_test_key(i)
		bloom_add(b, key)
		free(key)
		i = i + 1
	return b


void test_new_filter_is_empty():
	bloom_filter* b = bloom_new(4096, 5)
	assert_equal(4096, b.m)
	assert_equal(5, b.k)
	assert_equal(0, bloom_item_count(b))
	assert_equal(0, bloom_bit_count(b))
	# no bit is set, so every lookup is a guaranteed "definitely absent"
	assert_equal(0, bloom_maybe_contains(b, c"key0"))
	assert_equal(0, bloom_maybe_contains(b, c"anything"))
	assert_equal(0, bloom_maybe_contains(b, c""))
	bloom_free(b)


void test_no_false_negatives():
	bloom_filter* b = bloom_test_loaded()
	assert_equal(50, bloom_item_count(b))
	int i = 0
	while (i < 50):
		char* key = bloom_test_key(i)
		assert_equal(1, bloom_maybe_contains(b, key))
		free(key)
		i = i + 1
	bloom_free(b)


void test_absent_keys_mostly_reject():
	bloom_filter* b = bloom_test_loaded()
	int false_positives = 0
	int i = 0
	while (i < 100):
		char* key = bloom_test_other(i)
		false_positives = false_positives + bloom_maybe_contains(b, key)
		free(key)
		i = i + 1
	# generous structural bound: 50 keys in 4096 bits with k=5 gives a
	# theoretical false-positive rate well under 1e-5
	assert1(false_positives < 10)
	# the probes are deterministic (sha256): the observed count on the
	# x86 target is exactly 0, and every target must reproduce it
	assert_equal(0, false_positives)
	bloom_free(b)


void test_k_edge_one():
	bloom_filter* b = bloom_new(1024, 1)
	# a single add with k=1 sets exactly one bit
	bloom_add(b, c"key0")
	assert_equal(1, bloom_bit_count(b))
	int i = 0
	while (i < 10):
		char* key = bloom_test_key(i)
		bloom_add(b, key)
		free(key)
		i = i + 1
	assert_equal(11, bloom_item_count(b))
	assert1(bloom_bit_count(b) >= 1)
	assert1(bloom_bit_count(b) <= 10)
	i = 0
	while (i < 10):
		char* key = bloom_test_key(i)
		assert_equal(1, bloom_maybe_contains(b, key))
		free(key)
		i = i + 1
	bloom_free(b)


void test_k_edge_sixteen():
	bloom_filter* b = bloom_new(1024, 16)
	# power-of-two m keeps the odd step coprime to m, so one key's 16
	# probes hit 16 distinct bits
	bloom_add(b, c"key0")
	assert_equal(16, bloom_bit_count(b))
	int i = 0
	while (i < 10):
		char* key = bloom_test_key(i)
		bloom_add(b, key)
		free(key)
		i = i + 1
	i = 0
	while (i < 10):
		char* key = bloom_test_key(i)
		assert_equal(1, bloom_maybe_contains(b, key))
		free(key)
		i = i + 1
	assert1(bloom_bit_count(b) <= 160)
	bloom_free(b)


void test_duplicate_add_counts_items_not_bits():
	bloom_filter* b = bloom_new(4096, 5)
	bloom_add(b, c"key7")
	int bits_once = bloom_bit_count(b)
	# one k=5 key in 4096 bits: five distinct probe bits (observed)
	assert_equal(5, bits_once)
	assert_equal(1, bloom_item_count(b))
	bloom_add(b, c"key7")
	# items counts insertions (documented), the bit array is unchanged
	assert_equal(2, bloom_item_count(b))
	assert_equal(bits_once, bloom_bit_count(b))
	assert_equal(1, bloom_maybe_contains(b, c"key7"))
	bloom_free(b)


void test_serialize_round_trip():
	bloom_filter* b = bloom_test_loaded()
	int n = bloom_serialized_size(b)
	# 8 header bytes + bitset (4 size bytes + 4096/32 words * 4)
	assert_equal(8 + 4 + 128 * 4, n)
	char* buffer = malloc(n)
	bloom_serialize(b, buffer)
	bloom_filter* copy = bloom_deserialize(buffer)
	assert_equal(b.m, copy.m)
	assert_equal(b.k, copy.k)
	assert_equal(bloom_bit_count(b), bloom_bit_count(copy))
	# items is not serialized: the copy restarts at 0 (documented)
	assert_equal(0, bloom_item_count(copy))
	int i = 0
	while (i < 50):
		char* key = bloom_test_key(i)
		assert_equal(bloom_maybe_contains(b, key), bloom_maybe_contains(copy, key))
		assert_equal(1, bloom_maybe_contains(copy, key))
		free(key)
		i = i + 1
	i = 0
	while (i < 100):
		char* key = bloom_test_other(i)
		assert_equal(bloom_maybe_contains(b, key), bloom_maybe_contains(copy, key))
		free(key)
		i = i + 1
	bloom_free(copy)
	free(buffer)
	bloom_free(b)
	# a non-word-multiple m round-trips the partial last word too
	bloom_filter* small = bloom_new(100, 3)
	bloom_add(small, c"alpha")
	bloom_add(small, c"bravo")
	int sn = bloom_serialized_size(small)
	assert_equal(8 + 4 + 4 * 4, sn)
	char* sbuf = malloc(sn)
	bloom_serialize(small, sbuf)
	bloom_filter* scopy = bloom_deserialize(sbuf)
	assert_equal(100, scopy.m)
	assert_equal(3, scopy.k)
	assert_equal(bloom_bit_count(small), bloom_bit_count(scopy))
	assert_equal(1, bloom_maybe_contains(scopy, c"alpha"))
	assert_equal(1, bloom_maybe_contains(scopy, c"bravo"))
	assert_equal(bloom_maybe_contains(small, c"charlie"), bloom_maybe_contains(scopy, c"charlie"))
	bloom_free(scopy)
	free(sbuf)
	bloom_free(small)


void test_cross_target_determinism():
	# Values observed on the x86 target. The probe indexes are derived
	# from sha256 and masked to 31 bits, so the x64 twin must agree
	# exactly; a mismatch here means a word-size bug in the derivation.
	bloom_filter* b = bloom_test_loaded()
	assert_equal(243, bloom_bit_count(b))
	assert_equal(0, bloom_maybe_contains(b, c"other0"))
	assert_equal(0, bloom_maybe_contains(b, c"other42"))
	assert_equal(0, bloom_maybe_contains(b, c"definitely-not-here"))
	assert_equal(1, bloom_maybe_contains(b, c"key0"))
	assert_equal(1, bloom_maybe_contains(b, c"key49"))
	bloom_free(b)
