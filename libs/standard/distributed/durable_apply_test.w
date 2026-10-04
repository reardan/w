# wbuild: x64
import lib.testing
import lib.fake_fs
import libs.standard.distributed.durable_apply
import libs.standard.distributed.storage_maintenance


void test_applied_batch_lost_response_and_snapshot():
	fake_fs* fs = fake_fs_new(123)
	wal_recovery report
	lsm* store = lsm_open_policy_with_ops(fs.ops, c"app", 100000, WAL_RECOVER_STRICT_TRUNCATE, &report)
	u64* term = u64_new_int(1)
	lsm_batch* increment = lsm_batch_new()
	lsm_batch_put(increment, c"counter", c"1", 1)
	lsm_batch_put(increment, c"audit", c"request-A", 9)
	assert_equal(APPLY_COMMITTED, durable_apply_commit(store, 1, term, c"A", increment, c"1", 1))
	# Publication succeeded, response lost. Crash then replay/retry in a
	# later term must return the retained result without incrementing.
	lsm_close(store)
	fake_fs_crash(fs, cast(prng*, 0))
	store = lsm_open_policy_with_ops(fs.ops, c"app", 100000, WAL_RECOVER_STRICT_TRUNCATE, &report)
	char* result = 0
	int len = 0
	assert_equal(LSM_GET_FOUND, durable_apply_result(store, c"A", &result, &len))
	assert_equal(0, strcmp(result, c"1"))
	free(result)
	u64_set_int(term, 2)
	lsm_batch_put(increment, c"counter", c"2", 1)
	assert_equal(APPLY_DUPLICATE, durable_apply_commit(store, 2, term, c"A", increment, c"2", 1))
	result = lsm_get(store, c"counter", &len)
	assert_equal(0, strcmp(result, c"1"))
	free(result)
	assert_equal(APPLY_ERROR, durable_apply_commit(store, 4, term, c"B", increment, c"2", 1))
	char* blob = lsm_export(store, &len)
	lsm* restored = lsm_open_policy_with_ops(fs.ops, c"restored", 100000, WAL_RECOVER_STRICT_TRUNCATE, &report)
	assert1(lsm_import(restored, blob, len))
	u64* index = u64_new_int(2)
	assert1(durable_apply_snapshot_matches(restored, index, term))
	free(blob)
	u64_free(index)
	lsm_close(restored)
	lsm_batch_free(increment)
	u64_free(term)
	lsm_close(store)
	fake_fs_free(fs)


void test_application_failure_atomicity():
	for cut in range(1, 12):
		fake_fs* fs = fake_fs_new(cut)
		wal_recovery report
		lsm* store = lsm_open_policy_with_ops(fs.ops, c"app", 100000, WAL_RECOVER_STRICT_TRUNCATE, &report)
		assert1(lsm_sync(store))
		lsm_batch* batch = lsm_batch_new()
		lsm_batch_put(batch, c"a", c"1", 1)
		lsm_batch_put(batch, c"b", c"1", 1)
		u64* term = u64_new_int(1)
		fake_fs_fail_nth(fs, FAKE_FS_OP_ANY, cut, FAKE_FS_EIO)
		int status = durable_apply_commit(store, 1, term, c"request", batch, c"result", 6)
		lsm_close(store)
		for i in range(fs.rules.length): free(fs.rules[i])
		fs.rules.clear()
		fake_fs_crash(fs, cast(prng*, 0))
		store = lsm_open_policy_with_ops(fs.ops, c"app", 100000, WAL_RECOVER_STRICT_TRUNCATE, &report)
		assert1(cast(int, store) != 0)
		int applied = durable_apply_position(store, term)
		assert1(applied == 0 || applied == 1)
		if (status == APPLY_COMMITTED): assert_equal(1, applied)
		int len = 0
		char* value = lsm_get(store, c"a", &len)
		assert_equal(applied, value != 0)
		if (value != 0): free(value)
		value = lsm_get(store, c"b", &len)
		assert_equal(applied, value != 0)
		if (value != 0): free(value)
		lsm_batch_free(batch)
		u64_free(term)
		lsm_close(store)
		fake_fs_free(fs)


void test_pinned_generation_and_reclamation():
	fake_fs* fs = fake_fs_new(1)
	wal_recovery report
	lsm* store = lsm_open_policy_with_ops(fs.ops, c"tree", 100000, WAL_RECOVER_STRICT_TRUNCATE, &report)
	assert1(lsm_put(store, c"key", c"old", 3))
	assert1(lsm_flush(store))
	assert1(cast(int, lsm_view_new(store, 1)) == 0)
	lsm_view* view = lsm_view_new(store, 100000)
	assert1(cast(int, view) != 0)
	assert1(lsm_put(store, c"key", c"new", 3))
	assert1(lsm_flush(store))
	assert_equal(0, lsm_compact_bounded(store, 1))
	assert1(lsm_compact_bounded(store, 100000))
	int len = 0
	char* value = lsm_get(view.tree, c"key", &len)
	assert_equal(0, strcmp(value, c"old"))
	free(value)
	value = lsm_get(store, c"key", &len)
	assert_equal(0, strcmp(value, c"new"))
	free(value)
	lsm_view_free(view)
	int fd = storage_open(fs.ops, c"tree.sst999", FILE_OPS_CREATE | FILE_OPS_WRITE, 420)
	storage_close(fs.ops, fd)
	list[char*] candidates = new list[char*]
	candidates.push(c"tree.sst999")
	candidates.push(store.table_paths[0])
	candidates.push(c"tree.wal")
	assert_equal(1, lsm_reclaim(store, candidates, 3))
	assert1(fake_fs_exists(fs, store.table_paths[0]))
	assert1(fake_fs_exists(fs, c"tree.wal"))
	lsm_close(store)
	fake_fs_free(fs)


void test_failed_auto_flush_does_not_expose_durable_position():
	fake_fs* fs = fake_fs_new(9)
	wal_recovery report
	lsm* store = lsm_open_policy_with_ops(fs.ops, c"app", 1, WAL_RECOVER_STRICT_TRUNCATE, &report)
	assert1(lsm_sync(store))
	lsm_batch* batch = lsm_batch_new()
	lsm_batch_put(batch, c"counter", c"1", 1)
	u64* term = u64_new_int(1)
	# First write is the batch WAL record; second is the flush table.
	fake_fs_fail_nth(fs, FAKE_FS_OP_WRITE, 2, FAKE_FS_ENOSPC)
	assert_equal(APPLY_ERROR, durable_apply_commit(store, 1, term, c"A", batch, c"1", 1))
	assert1(lsm_failed(store))
	assert_equal(-1, durable_apply_position(store, term))
	lsm_batch_free(batch)
	u64_free(term)
	lsm_close(store)
	fake_fs_free(fs)
