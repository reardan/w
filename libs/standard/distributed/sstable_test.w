# wbuild: x64
import lib.testing
import libs.standard.distributed.sstable


# Distinct table paths per target so the 32- and 64-bit test binaries
# can run concurrently under wbuild without clobbering each other.
char* sst_test_path(char* name):
	char* word = itoa(__word_size__)
	char* prefix = strjoin(c"bin/sst_t", word)
	char* mid = strjoin(prefix, c"_")
	char* path = strjoin(mid, name)
	free(mid)
	free(prefix)
	free(word)
	return path


int* sst_len_out():
	return cast(int*, malloc(__word_size__))


char** sst_val_out():
	return cast(char**, malloc(__word_size__))


# "<prefix><i>" with the number zero-padded to `digits`, so strcmp
# order equals numeric order. Malloc'd; caller frees.
char* sst_pad_key(char* prefix, int i, int digits):
	char* num = itoa(i)
	int n = strlen(num)
	assert1(n <= digits)
	char* suffix = malloc(digits + 1)
	int j = 0
	while (j < digits - n):
		suffix[j] = '0'
		j = j + 1
	j = 0
	while (j < n):
		suffix[digits - n + j] = num[j]
		j = j + 1
	suffix[digits] = 0
	char* key = strjoin(prefix, suffix)
	free(suffix)
	free(num)
	return key


# "other<i>", never inserted anywhere. Malloc'd; caller frees.
char* sst_other(int i):
	char* num = itoa(i)
	char* key = strjoin(c"other", num)
	free(num)
	return key


# The shared 50-key fixture: key00..key49, each valued "v" + key.
void sst_build50(char* path):
	sstable_writer* w = sstable_writer_new(path)
	assert1(cast(int, w) != 0)
	int i = 0
	while (i < 50):
		char* key = sst_pad_key(c"key", i, 2)
		char* val = strjoin(c"v", key)
		assert_equal(1, sstable_writer_add(w, key, val, strlen(val), 0))
		free(val)
		free(key)
		i = i + 1
	assert_equal(1, sstable_writer_finish(w))


void test_roundtrip_with_tombstone():
	char* path = sst_test_path(c"round.sst")
	sstable_writer* w = sstable_writer_new(path)
	assert1(cast(int, w) != 0)
	assert_equal(1, sstable_writer_add(w, c"alpha", c"one", 3, 0))
	assert_equal(1, sstable_writer_add(w, c"bravo", c"two", 3, 0))
	assert_equal(1, sstable_writer_add(w, c"charlie", cast(char*, 0), 0, 1))
	assert_equal(1, sstable_writer_add(w, c"delta", c"four", 4, 0))
	assert_equal(1, sstable_writer_add(w, c"echo", c"five!", 5, 0))
	assert_equal(1, sstable_writer_finish(w))
	sstable* s = sstable_open(path)
	assert1(cast(int, s) != 0)
	assert_equal(5, sstable_count(s))
	assert_strings_equal(c"alpha", sstable_key_at(s, 0))
	assert_strings_equal(c"bravo", sstable_key_at(s, 1))
	assert_strings_equal(c"charlie", sstable_key_at(s, 2))
	assert_strings_equal(c"delta", sstable_key_at(s, 3))
	assert_strings_equal(c"echo", sstable_key_at(s, 4))
	assert_equal(0, sstable_is_tombstone_at(s, 0))
	assert_equal(0, sstable_is_tombstone_at(s, 1))
	assert_equal(1, sstable_is_tombstone_at(s, 2))
	assert_equal(0, sstable_is_tombstone_at(s, 3))
	assert_equal(0, sstable_is_tombstone_at(s, 4))
	char** v = sst_val_out()
	int* n = sst_len_out()
	assert_equal(1, sstable_get(s, c"alpha", v, n))
	assert_equal(3, n[0])
	assert_strings_equal(c"one", v[0])
	free(v[0])
	assert_equal(1, sstable_get(s, c"bravo", v, n))
	assert_equal(3, n[0])
	assert_strings_equal(c"two", v[0])
	free(v[0])
	assert_equal(1, sstable_get(s, c"delta", v, n))
	assert_equal(4, n[0])
	assert_strings_equal(c"four", v[0])
	free(v[0])
	assert_equal(1, sstable_get(s, c"echo", v, n))
	assert_equal(5, n[0])
	assert_strings_equal(c"five!", v[0])
	free(v[0])
	# tombstone: get answers 2 and leaves the out-params untouched
	assert_equal(2, sstable_get(s, c"charlie", v, n))
	# value_at mirrors that: 0 pointer, len 0
	n[0] = 99
	assert_equal(0, cast(int, sstable_value_at(s, 2, n)))
	assert_equal(0, n[0])
	# value_at on a live record returns a fresh disk copy
	char* copy = sstable_value_at(s, 3, n)
	assert_equal(4, n[0])
	assert_strings_equal(c"four", copy)
	free(copy)
	# absent keys (before, between, after the key range) answer 0
	assert_equal(0, sstable_get(s, c"aaa", v, n))
	assert_equal(0, sstable_get(s, c"cherry", v, n))
	assert_equal(0, sstable_get(s, c"zzz", v, n))
	sstable_close(s)
	free(cast(char*, v))
	free(cast(char*, n))
	free(path)


void test_empty_table():
	char* path = sst_test_path(c"empty.sst")
	sstable_writer* w = sstable_writer_new(path)
	assert1(cast(int, w) != 0)
	assert_equal(1, sstable_writer_finish(w))
	sstable* s = sstable_open(path)
	assert1(cast(int, s) != 0)
	assert_equal(0, sstable_count(s))
	char** v = sst_val_out()
	int* n = sst_len_out()
	assert_equal(0, sstable_get(s, c"anything", v, n))
	assert_equal(0, sstable_get(s, c"", v, n))
	# the bloom is written even for an empty table; no bit is set, so
	# every probe is a definite reject
	assert_equal(0, sstable_maybe_contains(s, c"anything"))
	sstable_close(s)
	free(cast(char*, v))
	free(cast(char*, n))
	free(path)


void test_binary_values():
	char* path = sst_test_path(c"binary.sst")
	char* blob = malloc(6)
	blob[0] = 0
	blob[1] = 255
	blob[2] = 10
	blob[3] = 0
	blob[4] = 200
	blob[5] = 7
	sstable_writer* w = sstable_writer_new(path)
	assert1(cast(int, w) != 0)
	assert_equal(1, sstable_writer_add(w, c"bin", blob, 6, 0))
	assert_equal(1, sstable_writer_add(w, c"text", c"plain", 5, 0))
	assert_equal(1, sstable_writer_finish(w))
	sstable* s = sstable_open(path)
	assert1(cast(int, s) != 0)
	assert_equal(2, sstable_count(s))
	char** v = sst_val_out()
	int* n = sst_len_out()
	assert_equal(1, sstable_get(s, c"bin", v, n))
	assert_equal(6, n[0])
	char* got = v[0]
	assert_equal(0, got[0] & 255)
	assert_equal(255, got[1] & 255)
	assert_equal(10, got[2] & 255)
	assert_equal(0, got[3] & 255)
	assert_equal(200, got[4] & 255)
	assert_equal(7, got[5] & 255)
	free(got)
	# same bytes through the iteration interface
	got = sstable_value_at(s, 0, n)
	assert_equal(6, n[0])
	assert_equal(255, got[1] & 255)
	assert_equal(200, got[4] & 255)
	free(got)
	assert_equal(1, sstable_get(s, c"text", v, n))
	assert_strings_equal(c"plain", v[0])
	free(v[0])
	sstable_close(s)
	free(cast(char*, v))
	free(cast(char*, n))
	free(blob)
	free(path)


void test_bloom_effectiveness():
	char* path = sst_test_path(c"bloom.sst")
	sst_build50(path)
	sstable* s = sstable_open(path)
	assert1(cast(int, s) != 0)
	assert_equal(50, sstable_count(s))
	# every present key must probe 1 — blooms have no false negatives
	int i = 0
	while (i < 50):
		char* key = sst_pad_key(c"key", i, 2)
		assert_equal(1, sstable_maybe_contains(s, key))
		free(key)
		i = i + 1
	# 100 absent keys: 50 keys at 10 bits/key with k=5 gives a ~1%
	# theoretical false-positive rate, so nearly all must reject
	int hits = 0
	i = 0
	while (i < 100):
		char* key = sst_other(i)
		hits = hits + sstable_maybe_contains(s, key)
		free(key)
		i = i + 1
	assert1(hits < 20)
	# the probes are sha256-derived and deterministic: the count
	# observed on the x86 target is exactly 0, and every target must
	# reproduce it (as must the number of bits the 50-key filter set)
	assert_equal(0, hits)
	assert_equal(196, bloom_bit_count(s.bloom))
	sstable_close(s)
	free(path)


void test_get_absent_never_found():
	char* path = sst_test_path(c"absent.sst")
	sst_build50(path)
	sstable* s = sstable_open(path)
	assert1(cast(int, s) != 0)
	char** v = sst_val_out()
	int* n = sst_len_out()
	# even when the bloom false-positives, the binary search catches
	# it: get must answer 0 for every absent key, never 1
	int i = 0
	while (i < 100):
		char* key = sst_other(i)
		assert_equal(0, sstable_get(s, key, v, n))
		free(key)
		i = i + 1
	# and every present key still resolves with its exact value
	i = 0
	while (i < 50):
		char* key = sst_pad_key(c"key", i, 2)
		char* val = strjoin(c"v", key)
		assert_equal(1, sstable_get(s, key, v, n))
		assert_equal(strlen(val), n[0])
		assert_strings_equal(val, v[0])
		free(v[0])
		free(val)
		free(key)
		i = i + 1
	sstable_close(s)
	free(cast(char*, v))
	free(cast(char*, n))
	free(path)


void test_corrupt_file_rejected():
	char* path = sst_test_path(c"garbage.sst")
	int fd = create_file(path, 420)
	assert1(fd >= 0)
	write_all(fd, c"this is not an sstable at all, not even close", 46)
	close(fd)
	assert_equal(0, cast(int, sstable_open(path)))
	# right magic, wrong version
	fd = create_file(path, 420)
	char* hdr = malloc(12)
	hdr[0] = 87
	hdr[1] = 83
	hdr[2] = 83
	hdr[3] = 84
	sstable_put_le32(hdr + 4, 99)
	sstable_put_le32(hdr + 8, 20)
	write_all(fd, hdr, 12)
	close(fd)
	free(hdr)
	assert_equal(0, cast(int, sstable_open(path)))
	# far too short to even hold a header
	fd = create_file(path, 420)
	write_all(fd, c"WS", 2)
	close(fd)
	assert_equal(0, cast(int, sstable_open(path)))
	# missing entirely
	char* nowhere = sst_test_path(c"never_written.sst")
	assert_equal(0, cast(int, sstable_open(nowhere)))
	free(nowhere)
	free(path)


void test_truncated_file_rejected():
	char* path = sst_test_path(c"trunc.sst")
	sstable_writer* w = sstable_writer_new(path)
	assert1(cast(int, w) != 0)
	assert_equal(1, sstable_writer_add(w, c"aa", c"first", 5, 0))
	assert_equal(1, sstable_writer_add(w, c"bb", c"second", 6, 0))
	assert_equal(1, sstable_writer_add(w, c"cc", c"third", 5, 0))
	assert_equal(1, sstable_writer_finish(w))
	# sanity: the intact file opens
	sstable* s = sstable_open(path)
	assert1(cast(int, s) != 0)
	assert_equal(3, sstable_count(s))
	sstable_close(s)
	# copy-rewrite the file a few bytes short (wal_test torn-tail
	# pattern): the last record is now truncated mid-value
	int fd = open(path, 0, 0)
	assert1(fd >= 0)
	int full = file_size(fd)
	char* buf = malloc(full)
	assert_equal(full, read_exact(fd, buf, full))
	close(fd)
	fd = create_file(path, 420)
	assert_equal(full - 5, write_all(fd, buf, full - 5))
	close(fd)
	assert_equal(0, cast(int, sstable_open(path)))
	# cut mid-bloom too: 12 header bytes plus a sliver of the filter
	fd = create_file(path, 420)
	assert_equal(15, write_all(fd, buf, 15))
	close(fd)
	assert_equal(0, cast(int, sstable_open(path)))
	free(buf)
	free(path)


void test_large_table():
	char* path = sst_test_path(c"large.sst")
	sstable_writer* w = sstable_writer_new(path)
	assert1(cast(int, w) != 0)
	int i = 0
	while (i < 300):
		char* key = sst_pad_key(c"key", i, 3)
		char* val = strjoin(c"v", key)
		assert_equal(1, sstable_writer_add(w, key, val, strlen(val), 0))
		free(val)
		free(key)
		i = i + 1
	assert_equal(1, sstable_writer_finish(w))
	sstable* s = sstable_open(path)
	assert1(cast(int, s) != 0)
	assert_equal(300, sstable_count(s))
	assert_strings_equal(c"key000", sstable_key_at(s, 0))
	assert_strings_equal(c"key299", sstable_key_at(s, 299))
	# the whole index is strictly ascending
	i = 1
	while (i < 300):
		assert1(strcmp(sstable_key_at(s, i - 1), sstable_key_at(s, i)) < 0)
		i = i + 1
	# spot-check gets across the range
	char** v = sst_val_out()
	int* n = sst_len_out()
	i = 0
	while (i < 300):
		char* key = sst_pad_key(c"key", i, 3)
		char* val = strjoin(c"v", key)
		assert_equal(1, sstable_get(s, key, v, n))
		assert_equal(7, n[0])
		assert_strings_equal(val, v[0])
		free(v[0])
		free(val)
		free(key)
		i = i + 37
	assert_equal(0, sstable_get(s, c"key300", v, n))
	assert_equal(0, sstable_get(s, c"kez", v, n))
	assert_equal(0, sstable_get(s, c"", v, n))
	# cross-target determinism: the bloom over 300 keys (m = 3000,
	# k = 5) sets an exact, sha256-determined number of bits; the
	# x64 twin must reproduce the x86-observed value
	assert_equal(1153, bloom_bit_count(s.bloom))
	sstable_close(s)
	free(cast(char*, v))
	free(cast(char*, n))
	free(path)
