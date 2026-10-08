# wbuild: x64
import lib.testing
import lib.fake_fs
import libs.standard.distributed.lsm
import libs.standard.distributed.raft_wal


void test_wal_faults():
	for fault in range(4):
		fake_fs* fs = fake_fs_new(17)
		wal_recovery rep
		wal* w = wal_open_policy_with_ops(fs.ops, c"log", WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(cast(int, w) != 0)
		assert1(wal_append(w, c"old", 3))
		assert1(wal_sync(w))
		int err = FAKE_FS_ENOSPC
		if (fault == 1): err = FAKE_FS_EIO
		if (fault == 2): err = FAKE_FS_ZERO
		if (fault == 3): err = FAKE_FS_EINTR
		fake_fs_fail_nth(fs, FAKE_FS_OP_WRITE, 1, err)
		int ok = wal_append(w, c"new", 3)
		assert_equal(fault == 3, ok)
		if (fault != 3): assert1(wal_failed(w))
		wal_close(w)
		fake_fs_crash(fs, cast(prng*, 0))
		w = wal_open_policy_with_ops(fs.ops, c"log", WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(cast(int, w) != 0)
		assert_equal(1, wal_record_count(w))
		wal_close(w)
		# A read error must refuse recovery, never truncate a good record.
		fake_fs_fail_nth(fs, FAKE_FS_OP_READ, 2, FAKE_FS_EIO)
		w = wal_open_policy_with_ops(fs.ops, c"log", WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(cast(int, w) == 0)
		assert_equal(WAL_ERR_IO, rep.status)
		assert_equal(19, fake_fs_file_size(fs, c"log"))
		fake_fs_free(fs)


void test_publication():
	for stage in range(3):
		fake_fs* fs = fake_fs_new(25)
		wal_recovery recovery
		wal* w = wal_open_policy_with_ops(fs.ops, c"log", WAL_RECOVER_STRICT_TRUNCATE, &recovery)
		assert1(wal_append(w, c"old", 3))
		assert1(wal_sync(w))
		wal* next = wal_rewrite_begin(w)
		assert1(wal_append(next, c"new", 3))
		int kind = FAKE_FS_OP_SYNC
		if (stage == 1): kind = FAKE_FS_OP_RENAME
		if (stage == 2): kind = FAKE_FS_OP_SYNC_DIR
		fake_fs_fail_nth(fs, kind, 1, FAKE_FS_EIO)
		fs_replace_report rep
		assert1(wal_rewrite_commit(w, next, &rep) != IO_OK)
		assert_equal(stage == 2, rep.renamed)
		if (stage == 2): assert1(wal_failed(w))
		wal_close(w)
		fake_fs_crash(fs, cast(prng*, 0))
		w = wal_open_policy_with_ops(fs.ops, c"log", WAL_RECOVER_STRICT_TRUNCATE, &recovery)
		assert1(cast(int, w) != 0)
		wal_reader* rd = wal_reader_open_with_ops(fs.ops, c"log")
		int len = 0
		char* value = wal_read_next(rd, &len)
		assert_equal(0, strcmp(value, c"old"))
		free(value)
		wal_reader_close(rd)
		wal_close(w)
		fake_fs_free(fs)


void test_lsm_crashes():
	# Cut every I/O in flush/publication, then recover the acknowledged value.
	for cut in range(1, 65):
		fake_fs* fs = fake_fs_new(cut)
		wal_recovery rep
		lsm* l = lsm_open_policy_with_ops(fs.ops, c"tree", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(cast(int, l) != 0)
		assert1(lsm_put(l, c"key", c"value", 5))
		assert1(lsm_sync(l))
		fake_fs_fail_nth(fs, FAKE_FS_OP_ANY, cut, FAKE_FS_EIO)
		lsm_flush(l)
		lsm_close(l)
		# Clear an unused cut rule before recovery.
		for i in range(fs.rules.length): free(fs.rules[i])
		fs.rules.clear()
		fake_fs_crash(fs, cast(prng*, 0))
		l = lsm_open_policy_with_ops(fs.ops, c"tree", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(cast(int, l) != 0)
		int len = 0
		char* value = lsm_get(l, c"key", &len)
		assert1(value != 0)
		assert_equal(5, len)
		assert_equal(0, strcmp(value, c"value"))
		free(value)
		lsm_close(l)
		fake_fs_free(fs)


void test_raft_gate():
	fake_fs* fs = fake_fs_new(41)
	wal_recovery rep
	raft_wal* rw = raft_wal_open_policy_with_ops(fs.ops, c"raft", WAL_RECOVER_STRICT_TRUNCATE, &rep)
	list[int] peers = new list[int]
	peers.push(2)
	raft* r = raft_new(1, peers, 100, 200, 20, 1)
	list[raft_msg*] staged = new list[raft_msg*]
	list[raft_msg*] out = new list[raft_msg*]
	u64_set_int(r.current_term, 1)
	staged.push(raft_msg_new(raft_msg_vote_reply, 1, 2, r.current_term))
	fake_fs_fail_nth(fs, FAKE_FS_OP_SYNC, 1, FAKE_FS_EIO)
	assert1(raft_wal_persist_release(rw, r, staged, out) != IO_OK)
	assert_equal(0, out.length)
	assert_equal(0, staged.length)
	assert1(raft_wal_failed(rw))
	raft_wal_close(rw)
	raft_free(r)
	fake_fs_free(fs)


void test_short_writes_and_torn_tail_sweep():
	for seed in range(1, 33):
		fake_fs* fs = fake_fs_new(seed)
		wal_recovery rep
		wal* w = wal_open_policy_with_ops(fs.ops, c"log", WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(wal_append(w, c"acknowledged", 12))
		assert1(wal_sync(w))
		fake_fs_set_sector(fs, 1)
		fake_fs_set_faults(fs, 1 << FAKE_FS_OP_WRITE, 800, 100, 0, 0, 0)
		assert1(wal_append(w, c"unacknowledged-tail", 19))
		fake_fs_set_faults(fs, 0, 0, 0, 0, 0, 0)
		wal_close(w)
		prng* rng = prng_new(seed)
		fake_fs_crash(fs, rng)
		w = wal_open_policy_with_ops(fs.ops, c"log", WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(cast(int, w) != 0)
		assert1(w.record_count == 1 || w.record_count == 2)
		wal_reader* reader = wal_reader_open_with_ops(fs.ops, c"log")
		int len = 0
		char* value = wal_read_next(reader, &len)
		assert_equal(0, strcmp(value, c"acknowledged"))
		free(value)
		wal_reader_close(reader)
		wal_close(w)
		prng_free(rng)
		fake_fs_free(fs)


void test_snapshot_publication_fault_sweep():
	for cut in range(1, 75):
		fake_fs* fs = fake_fs_new(cut)
		wal_recovery rep
		lsm* source = lsm_open_policy_with_ops(fs.ops, c"source", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(lsm_put(source, c"a", c"new", 3))
		assert1(lsm_put(source, c"b", c"new", 3))
		int len = 0
		char* blob = lsm_export(source, &len)
		lsm_close(source)
		lsm* target = lsm_open_policy_with_ops(fs.ops, c"target", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(lsm_put(target, c"a", c"old", 3))
		assert1(lsm_put(target, c"b", c"old", 3))
		assert1(lsm_flush(target))
		fake_fs_fail_nth(fs, FAKE_FS_OP_ANY, cut, FAKE_FS_EIO)
		int installed = lsm_import(target, blob, len)
		free(blob)
		lsm_close(target)
		for i in range(fs.rules.length): free(fs.rules[i])
		fs.rules.clear()
		prng* rng = prng_new(cut)
		fake_fs_crash(fs, rng)
		target = lsm_open_policy_with_ops(fs.ops, c"target", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(cast(int, target) != 0)
		char* a = lsm_get(target, c"a", &len)
		char* b = lsm_get(target, c"b", &len)
		assert1(a != 0 && b != 0)
		assert_equal(0, strcmp(a, b))
		assert1(strcmp(a, c"old") == 0 || strcmp(a, c"new") == 0)
		if (installed): assert_equal(0, strcmp(a, c"new"))
		free(a)
		free(b)
		lsm_close(target)
		prng_free(rng)
		fake_fs_free(fs)


void test_table_recovery_eio_preserves_manifest():
	fake_fs* fs = fake_fs_new(7)
	wal_recovery rep
	lsm* tree = lsm_open_policy_with_ops(fs.ops, c"tree", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
	assert1(lsm_put(tree, c"a", c"value", 5))
	assert1(lsm_flush(tree))
	int manifest_size = fake_fs_file_size(fs, c"tree.manifest")
	lsm_close(tree)
	# Table header read, after the manifest's validation and replay.
	fake_fs_fail_nth(fs, FAKE_FS_OP_READ, 9, FAKE_FS_EIO)
	tree = lsm_open_policy_with_ops(fs.ops, c"tree", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
	assert1(cast(int, tree) == 0)
	assert_equal(manifest_size, fake_fs_file_size(fs, c"tree.manifest"))
	tree = lsm_open_policy_with_ops(fs.ops, c"tree", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
	assert1(cast(int, tree) != 0)
	int len = 0
	char* value = lsm_get(tree, c"a", &len)
	assert_equal(0, strcmp(value, c"value"))
	free(value)
	lsm_close(tree)
	fake_fs_free(fs)


# Opening the adapter and replaying into a fresh Raft node are separate
# I/O operations. A successful initial scan cannot guarantee that the
# second open/read succeeds: service recovery must return failure,
# preserve the acknowledged log, and allow a later retry.
void test_raft_recovery_open_and_read_failures():
	for learner in range(2):
		for fault in range(4):
			fake_fs* fs = fake_fs_new(41)
			wal_recovery rep
			raft_wal* rw = raft_wal_open_policy_with_ops(fs.ops, c"raft", WAL_RECOVER_STRICT_TRUNCATE, &rep)
			assert1(rw != 0)
			list[int] peers = new list[int]
			peers.push(2)
			raft* live = 0
			if (learner): live = raft_new_learner(1, peers, 100, 200, 20, 1)
			else: live = raft_new(1, peers, 100, 200, 20, 1)
			u64_set_int(live.current_term, 7)
			live.voted_for = 2
			int wrote = 0
			assert_equal(IO_OK, raft_wal_persist(rw, live, &wrote))
			assert_equal(1, wrote)
			raft_free(live)
			int size = fake_fs_file_size(fs, c"raft")
			if (fault == 0): fake_fs_fail_nth(fs, FAKE_FS_OP_OPEN, 1, FAKE_FS_EIO)
			if (fault == 1): fake_fs_fail_nth(fs, FAKE_FS_OP_OPEN, 1, 24)  # EMFILE
			if (fault == 2): fake_fs_fail_nth(fs, FAKE_FS_OP_READ, 1, FAKE_FS_EIO)
			if (fault == 3): fake_fs_fail_nth(fs, FAKE_FS_OP_READ, 3, FAKE_FS_EIO)
			raft* recovered = 0
			if (learner): recovered = raft_wal_recover_learner(rw, 1, peers, 100, 200, 20, 1)
			else: recovered = raft_wal_recover(rw, 1, peers, 100, 200, 20, 1)
			assert1(recovered == 0)
			assert_equal(size, fake_fs_file_size(fs, c"raft"))
			assert_equal(0, raft_wal_failed(rw))
			if (learner): recovered = raft_wal_recover_learner(rw, 1, peers, 100, 200, 20, 1)
			else: recovered = raft_wal_recover(rw, 1, peers, 100, 200, 20, 1)
			assert1(recovered != 0)
			assert1(u64_eq(recovered.current_term, rw.term))
			assert_equal(2, recovered.voted_for)
			assert_equal(IO_OK, raft_wal_persist(rw, recovered, &wrote))
			assert_equal(0, wrote)
			raft_free(recovered)
			raft_wal_close(rw)
			peers.free()
			fake_fs_free(fs)
