# wbuild: x64
import lib.testing
import libs.standard.distributed.lsm
import lib.bytes
import lib.mem


/*
Crash-window tests for the LSM's durability contracts
(docs/projects/reliable_services.md, stage W1a): manifest replacement
interrupted before and after its rename, snapshot installation that
must never destroy the old generation, a failed manifest sync, a crash
between manifest publication and the data-wal reset, all-or-nothing
batches across a torn record, and the bounded ordered scan.

Crashes are simulated with wal.w's wal_test_crash_stage hook: the
replacement stops right before the named stage exactly as a dying
process would, the test closes the tree (which writes nothing), and a
reopen shows what recovery makes of the files left behind.
*/


# Distinct file prefixes per target so the 32- and 64-bit binaries can
# run concurrently. Malloc'd.
char* ld_prefix(char* name):
	char* word = itoa(__word_size__)
	char* stem = strjoin(c"bin/lsmd_t", word)
	char* mid = strjoin(stem, c"_")
	char* prefix = strjoin(mid, name)
	free(mid)
	free(stem)
	free(word)
	return prefix


int ld_exists(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	close(fd)
	return 1


int ld_table_exists(char* prefix, int seq):
	char* path = lsm_table_path(prefix, seq)
	int found = ld_exists(path)
	free(path)
	return found


# Empty wal and manifest, no tables or siblings left from earlier runs
# (table seqs in these scenarios stay small).
void ld_clean(char* prefix):
	char* wpath = strjoin(prefix, c".wal")
	char* mpath = strjoin(prefix, c".manifest")
	close(create_file(wpath, 420))
	close(create_file(mpath, 420))
	char* wnext = strjoin(wpath, c".next")
	char* mnext = strjoin(mpath, c".next")
	unlink(wnext)
	unlink(mnext)
	free(wnext)
	free(mnext)
	free(mpath)
	free(wpath)
	for seq in range(1, 40):
		char* path = lsm_table_path(prefix, seq)
		unlink(path)
		free(path)


void ld_expect(lsm* l, char* key, char* want):
	int n = 0
	char* got = lsm_get(l, key, &n)
	assert1(cast(int, got) != 0)
	assert_equal(strlen(want), n)
	assert_strings_equal(want, got)
	free(got)


void ld_expect_gone(lsm* l, char* key):
	int n = 99
	assert_equal(0, cast(int, lsm_get(l, key, &n)))
	assert_equal(0, n)


# Two flushed tables (seqs 1, 2) plus a memtable entry.
lsm* ld_two_tables(char* prefix):
	ld_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"a", c"1", 1))
	assert_equal(1, lsm_put(l, c"b", c"2", 1))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"a", c"11", 2))
	assert_equal(1, lsm_delete(l, c"b"))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"c", c"3", 1))
	assert_equal(2, lsm_sstable_count(l))
	return l


void ld_expect_two_tables_state(lsm* l):
	ld_expect(l, c"a", c"11")
	ld_expect_gone(l, c"b")
	ld_expect(l, c"c", c"3")


# ---- interrupted manifest replacement (compaction) ---------------------------

void test_compact_crash_before_rename_keeps_old_manifest():
	char* prefix = ld_prefix(c"cmp_pre")
	char* mnext = strjoin(prefix, c".manifest.next")
	int stage = FS_STAGE_SYNC_FILE
	while (stage <= FS_STAGE_RENAME):
		lsm* l = ld_two_tables(prefix)
		wal_test_crash_stage = stage
		assert_equal(0, lsm_compact(l))
		# before the rename nothing changed: still usable, still 2 tables,
		# and the merged table file is gone again
		assert_equal(0, lsm_failed(l))
		assert_equal(2, lsm_sstable_count(l))
		assert_equal(0, ld_table_exists(prefix, 3))
		ld_expect_two_tables_state(l)
		lsm_close(l)
		assert_equal(1, ld_exists(mnext))   # the crash left the sibling
		l = lsm_open(prefix, 1 << 20)
		assert1(cast(int, l) != 0)
		assert_equal(0, ld_exists(mnext))
		assert_equal(2, lsm_sstable_count(l))
		ld_expect_two_tables_state(l)
		# and compaction still works afterwards
		assert_equal(1, lsm_compact(l))
		assert_equal(1, lsm_sstable_count(l))
		ld_expect_two_tables_state(l)
		lsm_close(l)
		stage = stage + 2
	free(mnext)
	free(prefix)


void test_compact_crash_after_rename_serves_new_manifest():
	char* prefix = ld_prefix(c"cmp_post")
	lsm* l = ld_two_tables(prefix)
	wal_test_crash_stage = FS_STAGE_SYNC_DIR
	assert_equal(0, lsm_compact(l))
	# renamed: the tree switched to the merged table, but the directory
	# entry's durability is unknown, so the old tables are NOT unlinked
	# and the tree refuses further mutations until reopened
	assert_equal(1, lsm_failed(l))
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(1, ld_table_exists(prefix, 1))
	assert_equal(1, ld_table_exists(prefix, 2))
	assert_equal(1, ld_table_exists(prefix, 3))
	ld_expect_two_tables_state(l)
	assert_equal(0, lsm_put(l, c"d", c"4", 1))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(0, lsm_failed(l))
	assert_equal(1, lsm_sstable_count(l))
	ld_expect_two_tables_state(l)
	ld_expect_gone(l, c"d")
	lsm_close(l)
	free(prefix)


# ---- flush ordering ---------------------------------------------------------------

# The manifest record must be durable before the data wal is reset; a
# failed manifest sync fails the flush (checked) and the data survives.
void test_flush_failed_manifest_sync():
	char* prefix = ld_prefix(c"flush_sync")
	ld_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert_equal(1, lsm_put(l, c"a", c"1", 1))
	assert_equal(1, lsm_put(l, c"b", c"2", 1))
	wal_inject_sync_failures(l.manifest, 1)
	assert_equal(0, lsm_flush(l))
	assert_equal(1, lsm_failed(l))
	assert_equal(0, lsm_put(l, c"c", c"3", 1))
	assert_equal(0, lsm_flush(l))
	ld_expect(l, c"a", c"1")
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	ld_expect(l, c"a", c"1")
	ld_expect(l, c"b", c"2")
	ld_expect_gone(l, c"c")
	assert_equal(1, lsm_flush(l))
	lsm_close(l)
	free(prefix)


# A crash after the manifest names the new table but before the data
# wal reset replays the data wal on top of the table: same state.
void test_flush_crash_before_data_wal_reset():
	char* prefix = ld_prefix(c"flush_reset")
	ld_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert_equal(1, lsm_put(l, c"a", c"1", 1))
	assert_equal(1, lsm_delete(l, c"zz"))
	wal_test_crash_stage = FS_STAGE_RENAME
	assert_equal(0, lsm_flush(l))
	assert_equal(1, lsm_failed(l))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(2, lsm_memtable_count(l))
	ld_expect(l, c"a", c"1")
	ld_expect_gone(l, c"zz")
	assert_equal(1, lsm_flush(l))
	assert_equal(2, lsm_sstable_count(l))
	lsm_close(l)
	free(prefix)


# ---- snapshot installation never destroys the old generation ---------------

char* ld_snapshot_blob(int* len_out):
	char* prefix = ld_prefix(c"snap_src")
	ld_clean(prefix)
	lsm* src = lsm_open(prefix, 1 << 20)
	assert_equal(1, lsm_put(src, c"x", c"snap-x", 6))
	assert_equal(1, lsm_put(src, c"y", c"snap-y", 6))
	char* blob = lsm_export(src, len_out)
	assert1(cast(int, blob) != 0)
	lsm_close(src)
	free(prefix)
	return blob


# Old generation: one table (old1) plus a data-wal-only key (old2).
lsm* ld_old_generation(char* prefix):
	ld_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	assert_equal(1, lsm_put(l, c"old1", c"v1", 2))
	assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_put(l, c"old2", c"v2", 2))
	return l


void ld_expect_old_generation(lsm* l):
	ld_expect(l, c"old1", c"v1")
	ld_expect(l, c"old2", c"v2")
	ld_expect_gone(l, c"x")
	assert_equal(0, lsm_epoch(l))


void ld_expect_new_generation(lsm* l):
	ld_expect(l, c"x", c"snap-x")
	ld_expect(l, c"y", c"snap-y")
	ld_expect_gone(l, c"old1")
	ld_expect_gone(l, c"old2")
	assert_equal(1, lsm_epoch(l))


void test_snapshot_install_crash_before_switch():
	int blen = 0
	char* blob = ld_snapshot_blob(&blen)
	char* prefix = ld_prefix(c"snap_pre")
	int stage = FS_STAGE_SYNC_FILE
	while (stage <= FS_STAGE_RENAME):
		lsm* l = ld_old_generation(prefix)
		wal_test_crash_stage = stage
		assert_equal(0, lsm_import(l, blob, blen))
		# the manifest never switched: the live tree is untouched and
		# still usable, and the half-built generation's table is gone
		assert_equal(0, lsm_failed(l))
		ld_expect_old_generation(l)
		assert_equal(0, ld_table_exists(prefix, 2))
		lsm_close(l)
		l = lsm_open(prefix, 1 << 20)
		assert1(cast(int, l) != 0)
		ld_expect_old_generation(l)
		assert_equal(1, ld_table_exists(prefix, 1))
		# a retry installs cleanly
		assert_equal(1, lsm_import(l, blob, blen))
		ld_expect_new_generation(l)
		lsm_close(l)
		stage = stage + 2
	free(blob)
	free(prefix)


# Crash after the manifest switch, before the data wal was reset: the
# data wal still holds the OLD generation's mutations (epoch 0), and
# recovery must discard them rather than replay them over the snapshot.
void test_snapshot_install_crash_after_switch():
	int blen = 0
	char* blob = ld_snapshot_blob(&blen)
	char* prefix = ld_prefix(c"snap_post")
	lsm* l = ld_old_generation(prefix)
	wal_test_crash_skip = 1          # let the manifest publish through
	wal_test_crash_stage = FS_STAGE_RENAME
	assert_equal(0, lsm_import(l, blob, blen))
	assert_equal(1, lsm_failed(l))
	ld_expect_new_generation(l)
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	ld_expect_new_generation(l)
	assert_equal(0, lsm_memtable_count(l))
	assert_equal(1, lsm_put(l, c"z", c"after", 5))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	ld_expect_new_generation(l)
	ld_expect(l, c"z", c"after")
	lsm_close(l)
	free(blob)
	free(prefix)


void test_snapshot_install_success_reclaims_old_tables():
	int blen = 0
	char* blob = ld_snapshot_blob(&blen)
	char* prefix = ld_prefix(c"snap_ok")
	lsm* l = ld_old_generation(prefix)
	assert_equal(1, lsm_import(l, blob, blen))
	assert_equal(0, lsm_failed(l))
	ld_expect_new_generation(l)
	assert_equal(0, ld_table_exists(prefix, 1))
	assert_equal(1, ld_table_exists(prefix, 2))
	assert_equal(1, lsm_sstable_count(l))
	assert_equal(0, lsm_memtable_count(l))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert1(cast(int, l) != 0)
	ld_expect_new_generation(l)
	# a later clear is a generation switch too
	assert_equal(1, lsm_clear(l))
	assert_equal(2, lsm_epoch(l))
	ld_expect_gone(l, c"x")
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	assert_equal(2, lsm_epoch(l))
	assert_equal(0, lsm_total_entries(l))
	lsm_close(l)
	free(blob)
	free(prefix)


# Out-of-order or NUL-bearing keys are rejected before anything moves.
void test_import_rejects_unsorted_blob():
	char* prefix = ld_prefix(c"snap_bad")
	lsm* l = ld_old_generation(prefix)
	char* blob = malloc(30)
	blob[0] = 76
	blob[1] = 83
	blob[2] = 77
	blob[3] = 88
	store_le32(blob + 4, 1)
	store_le32(blob + 8, 2)
	store_le32(blob + 12, 1)
	blob[16] = 'b'
	store_le32(blob + 17, 0)
	store_le32(blob + 21, 1)
	blob[25] = 'a'               # "a" after "b": not ascending
	store_le32(blob + 26, 0)
	assert_equal(0, lsm_import(l, blob, 30))
	blob[25] = 0                 # a key containing NUL
	assert_equal(0, lsm_import(l, blob, 30))
	assert_equal(0, lsm_failed(l))
	ld_expect_old_generation(l)
	free(blob)
	lsm_close(l)
	free(prefix)


# ---- atomic batches -----------------------------------------------------------------

int ld_file_size(char* path):
	int fd = open(path, 0, 0)
	int size = file_size(fd)
	close(fd)
	return size


void test_batch_all_or_nothing_after_torn_record():
	char* prefix = ld_prefix(c"batch")
	ld_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	assert_equal(1, lsm_put(l, c"k0", c"zero", 4))
	lsm_batch* b1 = lsm_batch_new()
	lsm_batch_put(b1, c"k1", c"one", 3)
	lsm_batch_put(b1, c"k2", c"two", 3)
	lsm_batch_delete(b1, c"k0")
	assert_equal(3, lsm_batch_count(b1))
	assert_equal(1, lsm_apply_batch(l, b1))
	lsm_batch_free(b1)
	ld_expect(l, c"k1", c"one")
	ld_expect_gone(l, c"k0")
	lsm_batch* empty = lsm_batch_new()
	assert_equal(1, lsm_apply_batch(l, empty))
	lsm_batch_free(empty)
	assert_equal(1, lsm_sync(l))
	char* wpath = strjoin(prefix, c".wal")
	int before = ld_file_size(wpath)
	lsm_batch* b2 = lsm_batch_new()
	lsm_batch_put(b2, c"k3", c"three", 5)
	lsm_batch_put(b2, c"k4", c"four", 4)
	lsm_batch_delete(b2, c"k1")
	assert_equal(1, lsm_apply_batch(l, b2))
	lsm_batch_free(b2)
	ld_expect(l, c"k3", c"three")
	lsm_close(l)
	# tear the batch record: keep all but its last 3 bytes
	int after = ld_file_size(wpath)
	int fd = open(wpath, 0, 0)
	char* buf = malloc(after)
	assert_equal(after, read_exact(fd, buf, after))
	close(fd)
	fd = create_file(wpath, 420)
	assert_equal(after - 3, write_all(fd, buf, after - 3))
	close(fd)
	free(buf)
	wal_recovery rep
	l = lsm_open_policy(prefix, 1 << 20, WAL_RECOVER_STRICT_TRUNCATE, &rep)
	assert1(cast(int, l) != 0)
	assert_equal(WAL_TAIL_TORN, rep.tail)
	assert_equal(before, rep.bad_offset)
	# none of the torn batch applies; all of the earlier one does
	ld_expect_gone(l, c"k3")
	ld_expect_gone(l, c"k4")
	ld_expect(l, c"k1", c"one")
	ld_expect(l, c"k2", c"two")
	ld_expect_gone(l, c"k0")
	# batches survive a flush + reopen like any other mutation
	assert_equal(1, lsm_flush(l))
	lsm_close(l)
	l = lsm_open(prefix, 1 << 20)
	ld_expect(l, c"k2", c"two")
	lsm_close(l)
	free(wpath)
	free(prefix)


# ---- bounded ordered scan -----------------------------------------------------------

char* ld_key(int i):
	char* key = malloc(4)
	key[0] = 'k'
	key[1] = '0' + i / 10
	key[2] = '0' + i % 10
	key[3] = 0
	return key


void test_bounded_scan_pages():
	char* prefix = ld_prefix(c"scan")
	ld_clean(prefix)
	lsm* l = lsm_open(prefix, 1 << 20)
	for i in range(20):
		char* key = ld_key(i)
		assert_equal(1, lsm_put(l, key, c"v", 1))
		free(key)
		if (i == 9): assert_equal(1, lsm_flush(l))
	assert_equal(1, lsm_delete(l, c"k05"))
	assert_equal(1, lsm_put(l, c"k10", c"new", 3))
	# pages of 4: 19 live keys -> 5 pages, ascending, newest values
	char* start = 0
	int pages = 0
	int seen = 0
	int expect = 0
	int more = 1
	while (more):
		lsm_page* p = lsm_scan(l, start, 4, 1 << 20)
		assert_equal(1, p.ok)
		assert1(lsm_page_count(p) <= 4)
		for j in range(lsm_page_count(p)):
			if (expect == 5): expect = 6
			char* want = ld_key(expect)
			assert_strings_equal(want, p.keys[j])
			free(want)
			if (expect == 10): assert_strings_equal(c"new", p.values[j])
			expect = expect + 1
			seen = seen + 1
		if (pages == 0): assert_strings_equal(c"k04", p.resume)
		if (start != 0): free(start)
		start = 0
		if (p.resume != 0): start = mem_dup(p.resume, strlen(p.resume))
		else: more = 0
		lsm_page_free(p)
		pages = pages + 1
	assert_equal(19, seen)
	assert_equal(5, pages)
	# a byte budget smaller than any record still makes progress: one
	# record per page
	lsm_page* tiny = lsm_scan(l, c"k17", 100, 1)
	assert_equal(1, lsm_page_count(tiny))
	assert_strings_equal(c"k17", tiny.keys[0])
	assert_strings_equal(c"k18", tiny.resume)
	lsm_page_free(tiny)
	# from a start key that is not present: the next key up
	lsm_page* tail = lsm_scan(l, c"k155", 100, 1 << 20)
	assert_equal(4, lsm_page_count(tail))
	assert_strings_equal(c"k16", tail.keys[0])
	assert_equal(0, cast(int, tail.resume))
	lsm_page_free(tail)
	lsm_close(l)
	free(prefix)
