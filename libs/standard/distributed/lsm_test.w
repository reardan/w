# wbuild: x64
import lib.testing
import libs.standard.distributed.lsm


# Distinct file prefixes per target so the 32- and 64-bit test
# binaries can run concurrently under wbuild without clobbering each
# other. Malloc'd; caller frees.
char* lt_prefix(char* name):
	char* word = itoa(__word_size__)
	char* stem = strjoin(c"bin/lsm_t", word)
	char* mid = strjoin(stem, c"_")
	char* prefix = strjoin(mid, name)
	free(mid)
	free(stem)
	free(word)
	return prefix


# Full paths ("bin/<name>") of the directory entries under bin/ whose
# name starts with "<basename>.sst", where basename is the prefix
# without its "bin/" stem — the tree's on-disk table-file set.
# getdents(2) record layout as in tools/wbuildgen.w and
# libs/extras/vcs/tree.w: two word-sized ino/off fields, u16 d_reclen,
# then the NUL-terminated name (this test only runs on the x86/x64
# targets, whose legacy getdents share that layout). Malloc'd list of
# malloc'd strings; caller frees both.
list[char*] lt_sst_files(char* prefix):
	assert1(starts_with(prefix, c"bin/"))
	char* stem = strjoin(prefix + 4, c".sst")
	list[char*] paths = new list[char*]
	int fd = open(c"bin", 65536, 0)   # O_DIRECTORY
	assert1(fd >= 0)
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* record = buffer + off
			int reclen = (record[2 * __word_size__] & 255) | ((record[2 * __word_size__ + 1] & 255) << 8)
			char* entry_name = record + 2 * __word_size__ + 2
			if (starts_with(entry_name, stem)):
				paths.push(strjoin(c"bin/", entry_name))
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	free(stem)
	return paths


# How many "<prefix>.sst*" files exist on disk right now.
int lt_sst_file_count(char* prefix):
	list[char*] paths = lt_sst_files(prefix)
	int count = paths.length
	while (paths.length > 0):
		char* path = paths.pop()
		free(path)
	return count


# Truncate the prefix's wal and manifest and unlink the prefix's .sst
# files so reruns start clean — the on-disk-file-set assertions below
# need an exact, not merely unreachable, starting state.
void lt_clean(char* prefix):
	char* wpath = strjoin(prefix, c".wal")
	char* mpath = strjoin(prefix, c".manifest")
	int fd = create_file(wpath, 420)
	close(fd)
	fd = create_file(mpath, 420)
	close(fd)
	free(mpath)
	free(wpath)
	list[char*] stale = lt_sst_files(prefix)
	while (stale.length > 0):
		char* victim = stale.pop()
		unlink(victim)
		free(victim)


int* lt_len_out():
	return cast(int*, malloc(__word_size__))


# "<stem><i>" with the number zero-padded to `digits`, so strcmp
# order equals numeric order. Malloc'd; caller frees.
char* lt_pad_key(char* stem, int i, int digits):
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
	char* key = strjoin(stem, suffix)
	free(suffix)
	free(num)
	return key


# Assert lsm_get(key) returns exactly `want` (text value).
void lt_expect(lsm* l, char* key, char* want):
	int* n = lt_len_out()
	char* got = lsm_get(l, key, n)
	assert1(cast(int, got) != 0)
	assert_equal(strlen(want), n[0])
	assert_strings_equal(want, got)
	free(got)
	free(cast(char*, n))


# Assert lsm_get(key) answers absent/deleted: 0 pointer, len 0.
void lt_expect_gone(lsm* l, char* key):
	int* n = lt_len_out()
	n[0] = 99
	assert_equal(0, cast(int, lsm_get(l, key, n)))
	assert_equal(0, n[0])
	free(cast(char*, n))


void test_fresh_memtable_lifecycle():
	char* prefix = lt_prefix(c"fresh")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	lt_expect_gone(l, c"missing")
	assert_equal(1, lsm_put(l, c"alpha", c"one", 3))
	assert_equal(1, lsm_put(l, c"beta", c"two!", 4))
	lt_expect(l, c"alpha", c"one")
	lt_expect(l, c"beta", c"two!")
	assert_equal(2, lsm_memtable_count(l))
	assert_equal(0, lsm_sstable_count(l))
	assert_equal(2, lsm_total_entries(l))
	assert_equal(5 + 3 + 4 + 4, lsm_memtable_bytes(l))
	# delete shadows, then a re-put resurrects
	assert_equal(1, lsm_delete(l, c"alpha"))
	lt_expect_gone(l, c"alpha")
	assert_equal(2, lsm_memtable_count(l))
	assert_equal(1, lsm_put(l, c"alpha", c"again", 5))
	lt_expect(l, c"alpha", c"again")
	lsm_close(l)
	free(prefix)


void test_flush_and_newest_first_precedence():
	char* prefix = lt_prefix(c"flush")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"a", c"1", 1))
	assert_equal(1, lsm_put(l, c"b", c"2", 1))
	assert_equal(1, lsm_put(l, c"c", c"3", 1))
	assert_equal(1, lsm_flush(l))
	assert_equal(0, lsm_memtable_count(l))
	assert_equal(1, lsm_sstable_count(l))
	# reads now come from the table
	lt_expect(l, c"a", c"1")
	lt_expect(l, c"b", c"2")
	lt_expect(l, c"c", c"3")
	# re-put a with a new value: the memtable shadows the table
	assert_equal(1, lsm_put(l, c"a", c"one-new", 7))
	lt_expect(l, c"a", c"one-new")
	# and after a second flush the NEWEST table still wins
	assert_equal(1, lsm_flush(l))
	assert_equal(2, lsm_sstable_count(l))
	lt_expect(l, c"a", c"one-new")
	lt_expect(l, c"c", c"3")
	# flushing an empty memtable is a no-op
	assert_equal(1, lsm_flush(l))
	assert_equal(2, lsm_sstable_count(l))
	lsm_close(l)
	free(prefix)


void test_tombstone_across_tiers():
	char* prefix = lt_prefix(c"tomb")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"doomed", c"soon", 4))
	assert_equal(1, lsm_put(l, c"keep", c"safe", 4))
	assert_equal(1, lsm_flush(l))
	lt_expect(l, c"doomed", c"soon")
	# memtable tombstone shadows the table below
	assert_equal(1, lsm_delete(l, c"doomed"))
	lt_expect_gone(l, c"doomed")
	# flushed tombstone keeps shadowing from the newer table
	assert_equal(1, lsm_flush(l))
	assert_equal(2, lsm_sstable_count(l))
	assert_equal(0, lsm_memtable_count(l))
	lt_expect_gone(l, c"doomed")
	lt_expect(l, c"keep", c"safe")
	lsm_close(l)
	free(prefix)


void test_auto_flush():
	char* prefix = lt_prefix(c"auto")
	lt_clean(prefix)
	# tiny threshold: each put adds 3 key + 9 value = 12 bytes, so
	# every third put crosses 32 and flushes without lsm_flush calls
	lsm* l = lsm_open(prefix, 32)
	assert1(cast(int, l) != 0)
	int i = 0
	while (i < 8):
		char* key = lt_pad_key(c"k", i, 2)
		char* val = strjoin(c"value-", key)
		assert_equal(1, lsm_put(l, key, val, strlen(val)))
		free(val)
		free(key)
		i = i + 1
	assert1(lsm_sstable_count(l) >= 2)
	i = 0
	while (i < 8):
		char* key = lt_pad_key(c"k", i, 2)
		char* want = strjoin(c"value-", key)
		lt_expect(l, key, want)
		free(want)
		free(key)
		i = i + 1
	lsm_close(l)
	free(prefix)


void test_recovery_from_wal_only():
	char* prefix = lt_prefix(c"recwal")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"alpha", c"1", 1))
	assert_equal(1, lsm_put(l, c"beta", c"2", 1))
	assert_equal(1, lsm_put(l, c"gamma", c"3", 1))
	lsm_close(l)
	# no flush happened: everything must come back from the data wal
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(3, lsm_memtable_count(l))
	assert_equal(0, lsm_sstable_count(l))
	lt_expect(l, c"alpha", c"1")
	lt_expect(l, c"beta", c"2")
	lt_expect(l, c"gamma", c"3")
	lsm_close(l)
	free(prefix)


void test_recovery_after_flush():
	char* prefix = lt_prefix(c"recflush")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"a", c"old-a", 5))
	assert_equal(1, lsm_put(l, c"b", c"vb", 2))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"a", c"new-a", 5))
	assert_equal(1, lsm_put(l, c"c", c"vc", 2))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_sstable_count(l))
	# only the post-flush mutations replay into the memtable
	assert_equal(2, lsm_memtable_count(l))
	lt_expect(l, c"a", c"new-a")
	lt_expect(l, c"b", c"vb")
	lt_expect(l, c"c", c"vc")
	lsm_close(l)
	free(prefix)


void test_recovery_after_compact():
	char* prefix = lt_prefix(c"reccomp")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"a", c"A1", 2))
	assert_equal(1, lsm_put(l, c"b", c"B1", 2))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"b", c"B2", 2))
	assert_equal(1, lsm_put(l, c"c", c"C1", 2))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_delete(l, c"a"))
	assert_equal(1, lsm_put(l, c"d", c"D1", 2))
	assert_equal(1, lsm_flush(l))
	assert_equal(3, lsm_sstable_count(l))
	assert_equal(1, lsm_compact(l))
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(0, lsm_memtable_count(l))
	# the superseded tables were reclaimed from disk too
	assert_equal(1, lt_sst_file_count(prefix))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(0, lsm_memtable_count(l))
	lt_expect_gone(l, c"a")
	lt_expect(l, c"b", c"B2")
	lt_expect(l, c"c", c"C1")
	lt_expect(l, c"d", c"D1")
	lsm_close(l)
	free(prefix)


void test_compaction_semantics():
	char* prefix = lt_prefix(c"compsem")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"a", c"1", 1))
	assert_equal(1, lsm_put(l, c"b", c"2", 1))
	assert_equal(1, lsm_put(l, c"c", c"3", 1))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"b", c"22", 2))
	assert_equal(1, lsm_delete(l, c"c"))
	assert_equal(1, lsm_put(l, c"d", c"4", 1))
	assert_equal(1, lsm_flush(l))
	assert_equal(6, lsm_total_entries(l))
	assert_equal(1, lsm_compact(l))
	# raw record total shrinks: shadowed b and tombstoned c are gone
	assert_equal(3, lsm_total_entries(l))
	assert_equal(1, lsm_sstable_count(l))
	# sstable-level check of the merged table: exactly the survivor
	# set, sorted, no tombstones, newest values
	sstable* merged = l.tables[0]
	assert_equal(3, sstable_count(merged))
	assert_strings_equal(c"a", sstable_key_at(merged, 0))
	assert_strings_equal(c"b", sstable_key_at(merged, 1))
	assert_strings_equal(c"d", sstable_key_at(merged, 2))
	assert_equal(0, sstable_is_tombstone_at(merged, 0))
	assert_equal(0, sstable_is_tombstone_at(merged, 1))
	assert_equal(0, sstable_is_tombstone_at(merged, 2))
	int* n = lt_len_out()
	char* v = sstable_value_at(merged, 0, n)
	assert_equal(1, n[0])
	assert_strings_equal(c"1", v)
	free(v)
	v = sstable_value_at(merged, 1, n)
	assert_equal(2, n[0])
	assert_strings_equal(c"22", v)
	free(v)
	v = sstable_value_at(merged, 2, n)
	assert_equal(1, n[0])
	assert_strings_equal(c"4", v)
	free(v)
	free(cast(char*, n))
	lt_expect_gone(l, c"c")
	# compacting the single table again keeps the invariant
	assert_equal(1, lsm_compact(l))
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(3, lsm_total_entries(l))
	lt_expect(l, c"b", c"22")
	lsm_close(l)
	free(prefix)


void test_compaction_reclaims_superseded_tables():
	char* prefix = lt_prefix(c"reclaim")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"a", c"A1", 2))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"b", c"B1", 2))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_delete(l, c"a"))
	assert_equal(1, lsm_flush(l))
	# three tables (seq 1..3) exist on disk before the compaction
	assert_equal(3, lsm_sstable_count(l))
	assert_equal(3, lt_sst_file_count(prefix))
	assert_equal(1, lsm_compact(l))
	# EXACTLY the merged table (seq 4) remains on disk: the three
	# superseded files were unlinked after the manifest rewrite
	assert_equal(1, lt_sst_file_count(prefix))
	char* merged_path = lsm_table_path(prefix, 4)
	assert_strings_equal(merged_path, l.table_paths[0])
	int fd = open(merged_path, 0, 0)
	assert1(fd >= 0)
	close(fd)
	free(merged_path)
	# the data survived the reclaim...
	lt_expect_gone(l, c"a")
	lt_expect(l, c"b", c"B1")
	lsm_close(l)
	# ...and a recovery of the reclaimed tree still reads clean
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_sstable_count(l))
	lt_expect_gone(l, c"a")
	lt_expect(l, c"b", c"B1")
	lsm_close(l)
	free(prefix)


void test_recovery_reclaims_dangling_table():
	char* prefix = lt_prefix(c"recreclaim")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"a", c"1", 1))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"b", c"2", 1))
	lsm_close(l)
	# simulate a torn flush that got as far as a PARTIAL table write
	# and the manifest entry: seq 2's file exists but holds garbage
	char* dangling = lsm_table_path(prefix, 2)
	int fd = create_file(dangling, 420)
	assert1(fd >= 0)
	assert_equal(12, write_all(fd, c"partial-junk", 12))
	close(fd)
	char* mpath = strjoin(prefix, c".manifest")
	wal* mw = wal_open(mpath)
	assert1(cast(int, mw) != 0)
	char* rec = malloc(5)
	rec[0] = 1
	wal_put_le32(rec + 1, 2)
	assert_equal(1, wal_append(mw, rec, 5))
	free(rec)
	wal_close(mw)
	free(mpath)
	assert_equal(2, lt_sst_file_count(prefix))
	# recovery drops the dangling manifest entry AND unlinks its file
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(1, lt_sst_file_count(prefix))
	fd = open(dangling, 0, 0)
	assert1(fd < 0)
	# the data is intact and the dangling seq stays consumed: the
	# next flush writes seq 3, not a resurrected seq 2
	lt_expect(l, c"a", c"1")
	lt_expect(l, c"b", c"2")
	assert_equal(1, lsm_put(l, c"c", c"3", 1))
	assert_equal(1, lsm_flush(l))
	assert_equal(2, lt_sst_file_count(prefix))
	fd = open(dangling, 0, 0)
	assert1(fd < 0)
	char* third = lsm_table_path(prefix, 3)
	fd = open(third, 0, 0)
	assert1(fd >= 0)
	close(fd)
	free(third)
	lsm_close(l)
	free(dangling)
	free(prefix)


void test_torn_data_wal_tail():
	char* prefix = lt_prefix(c"torn")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"k1", c"v1", 2))
	assert_equal(1, lsm_put(l, c"k2", c"v2", 2))
	lsm_close(l)
	# hand-append garbage to the data wal: a crash mid-append
	char* wpath = strjoin(prefix, c".wal")
	int fd = open(wpath, 2, 0)
	assert1(fd >= 0)
	int size = file_size(fd)
	seek(fd, size, 0)
	assert_equal(17, write_all(fd, c"garbage-torn-tail", 17))
	close(fd)
	free(wpath)
	# the two valid records replay; the torn tail is ignored
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(2, lsm_memtable_count(l))
	lt_expect(l, c"k1", c"v1")
	lt_expect(l, c"k2", c"v2")
	# appends after recovery overwrite the torn bytes
	assert_equal(1, lsm_put(l, c"k3", c"v3", 2))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(3, lsm_memtable_count(l))
	lt_expect(l, c"k3", c"v3")
	lsm_close(l)
	free(prefix)


void test_torn_flush_manifest_recovery():
	char* prefix = lt_prefix(c"tornflush")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"a", c"1", 1))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"b", c"2", 1))
	lsm_close(l)
	# simulate a torn flush: the manifest names table seq 2 whose
	# file was never written (crash between manifest append and the
	# table write becoming visible)
	char* mpath = strjoin(prefix, c".manifest")
	wal* mw = wal_open(mpath)
	assert1(cast(int, mw) != 0)
	assert_equal(1, wal_record_count(mw))
	char* rec = malloc(5)
	rec[0] = 1
	wal_put_le32(rec + 1, 2)
	assert_equal(1, wal_append(mw, rec, 5))
	free(rec)
	wal_close(mw)
	free(mpath)
	# recovery drops the dangling LAST entry; data is intact (the
	# reclaim unlink of the never-written seq-2 file is a harmless
	# no-op — only seq 1 exists on disk)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(1, lsm_memtable_count(l))
	assert_equal(1, lt_sst_file_count(prefix))
	lt_expect(l, c"a", c"1")
	lt_expect(l, c"b", c"2")
	# the dangling seq stays consumed: the next flush gets a fresh
	# file and the rewritten manifest stays consistent across reopens
	assert_equal(1, lsm_put(l, c"c", c"3", 1))
	assert_equal(1, lsm_flush(l))
	assert_equal(2, lsm_sstable_count(l))
	assert_equal(2, lt_sst_file_count(prefix))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(2, lsm_sstable_count(l))
	assert_equal(0, lsm_memtable_count(l))
	lt_expect(l, c"a", c"1")
	lt_expect(l, c"b", c"2")
	lt_expect(l, c"c", c"3")
	lsm_close(l)
	free(prefix)


void test_binary_values_all_tiers():
	char* prefix = lt_prefix(c"binary")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	char* blob = malloc(5)
	blob[0] = 0
	blob[1] = 255
	blob[2] = 10
	blob[3] = 0
	blob[4] = 200
	assert_equal(1, lsm_put(l, c"bin1", blob, 5))
	int* n = lt_len_out()
	# memtable tier
	char* v = lsm_get(l, c"bin1", n)
	assert_equal(5, n[0])
	assert_equal(0, v[0] & 255)
	assert_equal(255, v[1] & 255)
	assert_equal(10, v[2] & 255)
	assert_equal(0, v[3] & 255)
	assert_equal(200, v[4] & 255)
	free(v)
	# flushed tier
	assert_equal(1, lsm_flush(l))
	v = lsm_get(l, c"bin1", n)
	assert_equal(5, n[0])
	assert_equal(255, v[1] & 255)
	assert_equal(200, v[4] & 255)
	free(v)
	# compacted tier (two tables so the merge really runs)
	char* blob2 = malloc(3)
	blob2[0] = 7
	blob2[1] = 0
	blob2[2] = 128
	assert_equal(1, lsm_put(l, c"bin2", blob2, 3))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_compact(l))
	v = lsm_get(l, c"bin1", n)
	assert_equal(5, n[0])
	assert_equal(0, v[0] & 255)
	assert_equal(255, v[1] & 255)
	free(v)
	v = lsm_get(l, c"bin2", n)
	assert_equal(3, n[0])
	assert_equal(7, v[0] & 255)
	assert_equal(0, v[1] & 255)
	assert_equal(128, v[2] & 255)
	free(v)
	# recovered tier: binary bytes survive the data wal replay too
	assert_equal(1, lsm_put(l, c"bin3", blob, 5))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_memtable_count(l))
	v = lsm_get(l, c"bin3", n)
	assert_equal(5, n[0])
	assert_equal(0, v[0] & 255)
	assert_equal(255, v[1] & 255)
	assert_equal(10, v[2] & 255)
	assert_equal(0, v[3] & 255)
	assert_equal(200, v[4] & 255)
	free(v)
	v = lsm_get(l, c"bin1", n)
	assert_equal(5, n[0])
	assert_equal(200, v[4] & 255)
	free(v)
	lsm_close(l)
	free(cast(char*, n))
	free(blob2)
	free(blob)
	free(prefix)


# Every key000..key199 whose number is not divisible by 3 must map to
# "v" + key; every third key must be gone.
void lt_verify_stress(lsm* l):
	int* n = lt_len_out()
	int j = 0
	while (j < 200):
		char* key = lt_pad_key(c"key", j, 3)
		if (j % 3 == 0):
			n[0] = 99
			assert_equal(0, cast(int, lsm_get(l, key, n)))
			assert_equal(0, n[0])
		else:
			char* want = strjoin(c"v", key)
			char* got = lsm_get(l, key, n)
			assert1(cast(int, got) != 0)
			assert_equal(strlen(want), n[0])
			assert_strings_equal(want, got)
			free(got)
			free(want)
		free(key)
		j = j + 1
	free(cast(char*, n))


void test_stress_stride():
	char* prefix = lt_prefix(c"stress")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	# scrambled inserts: key000..key199 in stride-37 order (37 is
	# coprime with 200, so every key appears once), flush every 20
	int i = 0
	while (i < 200):
		int k = (i * 37) % 200
		char* key = lt_pad_key(c"key", k, 3)
		char* val = strjoin(c"v", key)
		assert_equal(1, lsm_put(l, key, val, strlen(val)))
		free(val)
		free(key)
		if (i % 20 == 19):
			assert_equal(1, lsm_flush(l))
		i = i + 1
	# delete every 3rd key, flushing every 16 deletes
	int deleted = 0
	i = 0
	while (i < 200):
		if (i % 3 == 0):
			char* dkey = lt_pad_key(c"key", i, 3)
			assert_equal(1, lsm_delete(l, dkey))
			free(dkey)
			deleted = deleted + 1
			if (deleted % 16 == 0):
				assert_equal(1, lsm_flush(l))
		i = i + 1
	assert_equal(67, deleted)
	assert_equal(1, lsm_flush(l))
	assert1(lsm_sstable_count(l) > 2)
	lt_verify_stress(l)
	# full compaction: one table holding exactly the 133 survivors,
	# and exactly one table file left on disk
	assert_equal(1, lsm_compact(l))
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(0, lsm_memtable_count(l))
	assert_equal(1, lt_sst_file_count(prefix))
	assert_equal(133, lsm_total_entries(l))
	lt_verify_stress(l)
	lsm_close(l)
	# and the same picture after crash recovery
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(133, lsm_total_entries(l))
	lt_verify_stress(l)
	lsm_close(l)
	free(prefix)


# ---- export / import (full-scan snapshot surface, issue #314) ---------------

void test_export_empty_lsm():
	char* prefix = lt_prefix(c"expempty")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	int* n = lt_len_out()
	char* blob = lsm_export(l, n)
	assert_equal(12, n[0])
	assert_equal(76, blob[0] & 255)   # L
	assert_equal(83, blob[1] & 255)   # S
	assert_equal(77, blob[2] & 255)   # M
	assert_equal(88, blob[3] & 255)   # X
	assert_equal(1, wal_get_le32(blob + 4))
	assert_equal(0, wal_get_le32(blob + 8))
	# importing an empty blob into a tree with existing content wipes it
	assert_equal(1, lsm_put(l, c"gone", c"soon", 4))
	assert_equal(1, lsm_import(l, blob, n[0]))
	lt_expect_gone(l, c"gone")
	assert_equal(0, lsm_total_entries(l))
	assert_equal(0, lsm_sstable_count(l))
	free(blob)
	free(cast(char*, n))
	lsm_close(l)
	free(prefix)


void test_export_tombstone_excluded():
	char* prefix = lt_prefix(c"exptomb")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"keep", c"safe", 4))
	assert_equal(1, lsm_put(l, c"doomed", c"soon", 4))
	# flush so the tombstone must also shadow an on-disk record, not
	# merely a memtable one
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_delete(l, c"doomed"))
	int* n = lt_len_out()
	char* blob = lsm_export(l, n)
	assert_equal(1, wal_get_le32(blob + 8))   # exactly one surviving record
	char* prefix2 = lt_prefix(c"exptomb2")
	lt_clean(prefix2)
	lsm* l2 = lsm_open(prefix2, 1 << 20)
	assert1(cast(int, l2) != 0)
	assert_equal(1, lsm_import(l2, blob, n[0]))
	lt_expect(l2, c"keep", c"safe")
	lt_expect_gone(l2, c"doomed")
	assert_equal(1, lsm_total_entries(l2))
	free(blob)
	free(cast(char*, n))
	lsm_close(l)
	lsm_close(l2)
	free(prefix2)
	free(prefix)


void test_export_memtable_shadows_sstable():
	char* prefix = lt_prefix(c"expshadow")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"a", c"old", 3))
	assert_equal(1, lsm_put(l, c"b", c"keep-b", 6))
	assert_equal(1, lsm_flush(l))
	# a's newer value sits only in the memtable, above the flushed table
	assert_equal(1, lsm_put(l, c"a", c"new", 3))
	int* n = lt_len_out()
	char* blob = lsm_export(l, n)
	char* prefix2 = lt_prefix(c"expshadow2")
	lt_clean(prefix2)
	lsm* l2 = lsm_open(prefix2, 1 << 20)
	assert1(cast(int, l2) != 0)
	assert_equal(1, lsm_import(l2, blob, n[0]))
	lt_expect(l2, c"a", c"new")
	lt_expect(l2, c"b", c"keep-b")
	assert_equal(2, lsm_total_entries(l2))
	free(blob)
	free(cast(char*, n))
	lsm_close(l)
	lsm_close(l2)
	free(prefix2)
	free(prefix)


# Export a tree that has been through flush, an overwrite, a delete
# and a binary-valued put, import the blob into an unrelated tree
# (whose own prior content must be wiped, not merged), then verify
# the destination matches value-for-value AND that re-exporting the
# imported tree reproduces byte-identical output — the merge is a
# deterministic sorted scan, so import really is the inverse of
# export.
void test_export_import_roundtrip():
	char* prefix = lt_prefix(c"exportrt")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"alpha", c"1", 1))
	assert_equal(1, lsm_put(l, c"beta", c"2", 1))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"beta", c"22", 2))
	assert_equal(1, lsm_put(l, c"gamma", c"3", 1))
	assert_equal(1, lsm_delete(l, c"alpha"))
	char* binval = malloc(4)
	binval[0] = 0
	binval[1] = 255
	binval[2] = 7
	binval[3] = 0
	assert_equal(1, lsm_put(l, c"bin", binval, 4))
	int* n = lt_len_out()
	char* exported = lsm_export(l, n)
	int elen = n[0]
	# a fresh, unrelated tree with existing content the import must wipe
	char* prefix2 = lt_prefix(c"exportrt2")
	lt_clean(prefix2)
	lsm* l2 = lsm_open(prefix2, 1 << 20)
	assert1(cast(int, l2) != 0)
	assert_equal(1, lsm_put(l2, c"stale", c"gone-after-import", 18))
	assert_equal(1, lsm_import(l2, exported, elen))
	lt_expect_gone(l2, c"stale")
	lt_expect_gone(l2, c"alpha")
	lt_expect(l2, c"beta", c"22")
	lt_expect(l2, c"gamma", c"3")
	char* got = lsm_get(l2, c"bin", n)
	assert1(cast(int, got) != 0)
	assert_equal(4, n[0])
	assert_equal(0, got[0] & 255)
	assert_equal(255, got[1] & 255)
	assert_equal(7, got[2] & 255)
	assert_equal(0, got[3] & 255)
	free(got)
	assert_equal(3, lsm_total_entries(l2))
	char* exported2 = lsm_export(l2, n)
	assert_equal(elen, n[0])
	int i = 0
	while (i < elen):
		assert_equal(exported[i] & 255, exported2[i] & 255)
		i = i + 1
	free(exported2)
	free(exported)
	free(cast(char*, n))
	free(binval)
	lsm_close(l)
	lsm_close(l2)
	free(prefix2)
	free(prefix)


# A malformed blob (too short, wrong magic, or a record count/length
# that overruns the buffer) is rejected WITHOUT touching the tree —
# lsm_import validates the whole buffer before ever calling lsm_clear,
# so a bad inbound snapshot can never corrupt a good one.
void test_import_rejects_malformed_blob():
	char* prefix = lt_prefix(c"expmal")
	lt_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"safe", c"value", 5))
	# too short to even carry the 12-byte header
	assert_equal(0, lsm_import(l, c"xx", 2))
	# right length, wrong magic
	char* bad_magic = malloc(12)
	bad_magic[0] = 88
	bad_magic[1] = 88
	bad_magic[2] = 88
	bad_magic[3] = 88
	wal_put_le32(bad_magic + 4, 1)
	wal_put_le32(bad_magic + 8, 0)
	assert_equal(0, lsm_import(l, bad_magic, 12))
	free(bad_magic)
	# right magic, a record count the buffer cannot possibly hold
	char* bad_count = malloc(12)
	bad_count[0] = 76
	bad_count[1] = 83
	bad_count[2] = 77
	bad_count[3] = 88
	wal_put_le32(bad_count + 4, 1)
	wal_put_le32(bad_count + 8, 5)
	assert_equal(0, lsm_import(l, bad_count, 12))
	free(bad_count)
	# none of the rejected imports touched the tree
	lt_expect(l, c"safe", c"value")
	assert_equal(1, lsm_total_entries(l))
	lsm_close(l)
	free(prefix)
