# wbuild: x64 timeout=180000
import lib.testing
import lib.fake_fs
import libs.standard.distributed.kv_state
import libs.standard.distributed.durable_apply
import libs.standard.distributed.raft_wal
import libs.standard.distributed.raft_wire

char* stream_path(char* suffix):
	char* bits = itoa(__word_size__)
	char* prefix = strjoin(c"bin/stream_", bits)
	char* path = strjoin(prefix, suffix)
	free(prefix)
	free(bits)
	return path

void stream_clean(char* prefix):
	char* path = strjoin(prefix, c".wal")
	unlink(path)
	free(path)
	path = strjoin(prefix, c".manifest")
	unlink(path)
	free(path)
	for i in range(1, 20):
		path = lsm_table_path(prefix, i)
		unlink(path)
		free(path)

raft* stream_node(int self, int peer):
	list[int] peers = new list[int]
	peers.push(peer)
	if (self == 1 || self == 2): peers.push(3)
	else: peers.push(2)
	raft* r = raft_new(self, peers, 100, 200, 20, self)
	u64_set_int(r.current_term, 1)
	return r

void stream_drop(list[raft_msg*] messages):
	for i in range(messages.length): raft_msg_free(messages[i])
	messages.clear()

# Produce >9MiB with only one 32KiB generation buffer. The largest value
# is 768KiB; import/export and transfer never retain all value bytes.
snapshot_file* stream_fixture(char* path):
	snapshot_file* s = snapshot_file_new(cast(file_ops*, 0), path)
	assert1(cast(int, s) != 0)
	char* header = malloc(12)
	mem_copy(cast(char*, header), c"LSMX", 4)
	store_le32(header + 4, 1)
	store_le32(header + 8, 13)
	assert1(snapshot_file_append(s, header, 12))
	char* value = malloc(SNAPSHOT_FILE_CHUNK)
	for i in range(SNAPSHOT_FILE_CHUNK): value[i] = i % 251
	for i in range(13):
		store_le32(header, 1)
		header[4] = 65 + i
		store_le32(header + 5, 786432)
		assert1(snapshot_file_append(s, header, 9))
		for j in range(24): assert1(snapshot_file_append(s, value, SNAPSHOT_FILE_CHUNK))
	free(value)
	free(header)
	assert1(snapshot_file_seal(s))
	assert1(s.length > RAFT_SNAPSHOT_LIMIT)
	return s

void stream_expect_value(lsm* store):
	int length = 0
	char* value = lsm_get(store, c"M", &length)
	assert_equal(786432, length)
	for i in range(length): assert_equal((i % SNAPSHOT_FILE_CHUNK) % 251, value[i] & 255)
	free(value)

void test_stream_snapshot_end_to_end():
	char* scratch = stream_path(c"_scratch")
	char* source_path = stream_path(c"_source")
	char* target_path = stream_path(c"_target")
	char* log_path = stream_path(c"_raft")
	stream_clean(source_path)
	stream_clean(target_path)
	unlink(log_path)
	snapshot_file* fixture = stream_fixture(scratch)
	lsm* source = lsm_open(source_path, 1048576)
	assert1(lsm_import_file(source, fixture))
	snapshot_file_free(fixture)
	raft* leader = stream_node(1, 2)
	raft* follower = stream_node(2, 1)
	leader.state = raft_leader
	raft* fast = stream_node(3, 1)
	fast.log.push(raft_entry_new(fast.current_term, c"", 0))
	u64_set_int(fast.commit_index, 1)
	u64_set_int(fast.last_applied, 1)
	leader.log.push(raft_entry_new(leader.current_term, c"", 0))
	u64_set_int(leader.commit_index, 1)
	u64_set_int(leader.last_applied, 1)
	assert1(kv_take_snapshot_file(leader, source, scratch))
	assert_equal(0, cast(int, leader.snap_data))
	assert1(leader.snap_len > RAFT_SNAPSHOT_LIMIT)
	lsm_close(source)
	leader.log.push(raft_entry_new(leader.current_term, c"next", 4))
	u64_set_int(leader.next_index[3], 2)
	u64_set_int(leader.match_index[3], 1)
	raft_wal* rw = raft_wal_open(log_path)
	assert1(cast(int, rw) != 0)
	raft_enable_snapshot_files(follower, cast(file_ops*, 0), scratch)
	list[raft_msg*] replies = new list[raft_msg*]
	list[raft_msg*] next = new list[raft_msg*]
	int steps = 0
	while (raft_has_pending_snapshot(follower) == 0 && steps < 400):
		raft_msg* chunk = raft_make_peer_msg(leader, 2)
		assert_equal(raft_msg_snapshot_chunk, chunk.type)
		assert1(chunk.snap_len <= SNAPSHOT_FILE_CHUNK)
		int wire_len = raft_wire_size(chunk)
		char* wire = malloc(wire_len)
		raft_wire_encode(chunk, wire)
		raft_msg* decoded = raft_wire_decode(wire, wire_len)
		assert1(cast(int, decoded) != 0)
		free(wire)
		raft_msg_free(chunk)
		if (steps == 3):
			# A process restart discards the unlinked partial file, and the
			# nonzero next chunk receives offset zero instead of installing.
			raft_free(follower)
			follower = stream_node(2, 1)
			raft_enable_snapshot_files(follower, cast(file_ops*, 0), scratch)
		if (steps == 5):
			decoded.snap_data[0] = decoded.snap_data[0] ^ 1
			raft_on_msg(follower, decoded, steps, replies)
			assert_equal(0, replies.length)
			decoded.snap_data[0] = decoded.snap_data[0] ^ 1
		raft_on_msg(follower, decoded, steps, replies)
		assert_equal(0, cast(int, follower.snap_data))
		assert_equal(0, cast(int, follower.pending_snap_data))
		if (cast(int, follower.incoming_snapshot) != 0):
			assert_equal(0, cast(int, follower.incoming_snapshot.snap_data))
			assert1(follower.incoming_file.length <= leader.snap_len)
		if (steps == 7): raft_on_msg(follower, decoded, steps, replies)
		raft_msg_free(decoded)
		# Persist before releasing final success (intermediate progress does
		# not claim a durable install). Fast-peer appends remain schedulable.
		list[raft_msg*] released = new list[raft_msg*]
		assert_equal(IO_OK, raft_wal_persist_release(rw, follower, replies, released))
		stream_drop(replies)
		replies = released
		if (steps % 40 == 0):
			raft_msg* append = raft_make_peer_msg(leader, 3)
			list[raft_msg*] fast_replies = new list[raft_msg*]
			raft_on_msg(fast, append, steps, fast_replies)
			raft_msg_free(append)
			for i in range(fast_replies.length): raft_on_msg(leader, fast_replies[i], steps, next)
			stream_drop(fast_replies)
		# Drop one acknowledgement: retransmit the same chunk after reconnect.
		if (steps != 9):
			for i in range(replies.length): raft_on_msg(leader, replies[i], steps, next)
		stream_drop(replies)
		stream_drop(next)
		steps = steps + 1
	assert1(steps < 400)
	assert_equal(leader.snap_hash, follower.snap_hash)
	assert_equal(2, u64_to_int(leader.next_index[2]))
	assert_equal(2, raft_commit_int(leader))
	assert_equal(2, raft_commit_int(fast))
	assert1(raft_wal_sync(rw, follower) >= 0)
	raft_free(follower)
	raft_wal_close(rw)
	rw = raft_wal_open(log_path)
	assert1(cast(int, rw) != 0)
	list[int] peers = new list[int]
	peers.push(1)
	follower = raft_wal_recover(rw, 2, peers, 100, 200, 20, 2)
	assert1(cast(int, follower) != 0)
	assert_equal(leader.snap_hash, follower.snap_hash)
	assert1(cast(int, follower.pending_snap_file) != 0)
	lsm* target = lsm_open(target_path, 1048576)
	assert_equal(0, kv_apply_pending(follower, target))
	assert_equal(0, raft_has_pending_snapshot(follower))
	stream_expect_value(target)
	lsm_close(target)
	target = lsm_open(target_path, 1048576)
	stream_expect_value(target)
	lsm_close(target)
	raft_free(follower)
	raft_free(leader)
	raft_free(fast)
	raft_wal_close(rw)
	stream_clean(source_path)
	stream_clean(target_path)
	unlink(log_path)
	free(scratch)
	free(source_path)
	free(target_path)
	free(log_path)

void test_stream_publication_failures():
	for stage in range(FS_STAGE_SYNC_FILE, FS_STAGE_SYNC_DIR + 1):
		if (stage == FS_STAGE_CLOSE): continue
		char* prefix = stream_path(c"_failure")
		stream_clean(prefix)
		lsm* store = lsm_open(prefix, 100000)
		assert1(lsm_put(store, c"A", c"old", 3))
		assert1(lsm_flush(store))
		snapshot_file* s = snapshot_file_new(cast(file_ops*, 0), prefix)
		char* blob = malloc(24)
		mem_copy(cast(char*, blob), c"LSMX", 4)
		store_le32(blob + 4, 1)
		store_le32(blob + 8, 1)
		store_le32(blob + 12, 1)
		blob[16] = 65
		store_le32(blob + 17, 3)
		mem_copy(cast(char*, blob) + 21, c"new", 3)
		assert1(snapshot_file_append(s, blob, 24))
		free(blob)
		assert1(snapshot_file_seal(s))
		wal_test_crash_stage = stage
		assert_equal(0, lsm_import_file(store, s))
		lsm_close(store)
		store = lsm_open(prefix, 100000)
		int length = 0
		char* value = lsm_get(store, c"A", &length)
		if (stage < FS_STAGE_SYNC_DIR): assert_strings_equal(c"old", value)
		else: assert_strings_equal(c"new", value)
		free(value)
		lsm_close(store)
		snapshot_file_free(s)
		stream_clean(prefix)
		free(prefix)

void test_stream_limits_and_checksum():
	char* prefix = stream_path(c"_limits")
	for length in range(1, 140):
		snapshot_file* s = snapshot_file_new(cast(file_ops*, 0), prefix)
		char* data = malloc(140)
		for i in range(length): data[i] = i
		assert1(snapshot_file_append(s, data, length))
		assert1(snapshot_file_seal(s))
		assert_equal(raft_snapshot_checksum(data, length), s.hash)
		assert_equal(0, snapshot_file_append(s, data, 1))
		free(data)
		snapshot_file_free(s)
	snapshot_file* s = snapshot_file_new(cast(file_ops*, 0), prefix)
	assert_equal(0, snapshot_file_append(s, c"", SNAPSHOT_FILE_LIMIT + 1))
	snapshot_file_free(s)
	free(prefix)

void test_stream_wal_publication_failures():
	for stage in range(FS_STAGE_SYNC_FILE, FS_STAGE_SYNC_DIR + 1):
		if (stage == FS_STAGE_CLOSE): continue
		char* path = stream_path(c"_wal_failure")
		unlink(path)
		raft_wal* rw = raft_wal_open(path)
		raft* r = stream_node(1, 2)
		r.log.push(raft_entry_new(r.current_term, c"", 0))
		u64_set_int(r.last_applied, 1)
		u64_set_int(r.commit_index, 1)
		assert1(raft_take_snapshot(r, c"old", 3))
		assert1(raft_wal_sync(rw, r) > 0)
		r.log.push(raft_entry_new(r.current_term, c"", 0))
		u64_set_int(r.last_applied, 2)
		u64_set_int(r.commit_index, 2)
		snapshot_file* s = snapshot_file_new(cast(file_ops*, 0), path)
		assert1(snapshot_file_append(s, c"new", 3))
		assert1(raft_take_snapshot_file(r, s))
		snapshot_file_free(s)
		list[raft_msg*] staged = new list[raft_msg*]
		list[raft_msg*] out = new list[raft_msg*]
		staged.push(raft_msg_new(raft_msg_append_reply, 1, 2, r.current_term))
		wal_test_crash_stage = stage
		assert1(raft_wal_persist_release(rw, r, staged, out) != IO_OK)
		assert_equal(0, out.length)
		assert1(raft_wal_failed(rw))
		raft_free(r)
		raft_wal_close(rw)
		rw = raft_wal_open(path)
		assert1(cast(int, rw) != 0)
		list[int] peers = new list[int]
		peers.push(2)
		peers.push(3)
		r = raft_wal_recover(rw, 1, peers, 100, 200, 20, 1)
		assert1(cast(int, r) != 0)
		if (stage < FS_STAGE_SYNC_DIR):
			assert_equal(1, raft_snap_base(r))
			assert_strings_equal(c"old", r.pending_snap_data)
		else:
			assert_equal(2, raft_snap_base(r))
			assert1(cast(int, r.pending_snap_file) != 0)
			char* bytes = malloc(4)
			assert1(snapshot_file_read(r.pending_snap_file, 0, bytes, 3))
			bytes[3] = 0
			assert_strings_equal(c"new", bytes)
			free(bytes)
		raft_free(r)
		raft_wal_close(rw)
		unlink(path)
		free(path)

void test_stream_invalid_install_and_timeout():
	char* path = stream_path(c"_invalid")
	raft* r = stream_node(2, 1)
	raft_enable_snapshot_files(r, cast(file_ops*, 0), path)
	raft_msg* m = raft_msg_new(raft_msg_snapshot_chunk, 1, 2, r.current_term)
	u64_set_int(m.prev_log_index, 1)
	u64_set_int(m.prev_log_term, 1)
	m.snap_config.push(1)
	m.snap_config.push(2)
	m.chunk_total = RAFT_SNAPSHOT_LIMIT + 1
	m.chunk_hash = 5
	m.snap_len = 3
	m.snap_data = strclone(c"abc")
	m.chunk_crc = raft_snapshot_chunk_checksum(m)
	list[raft_msg*] out = new list[raft_msg*]
	raft_on_msg(r, m, 0, out)
	stream_drop(out)
	assert1(cast(int, r.incoming_file) != 0)
	assert_equal(3, r.incoming_file.length)
	# An unrelated legacy message cannot use an active file transfer to
	# bypass the old blob admission limit or borrow its unsealed contents.
	raft_msg* bad = raft_msg_new(raft_msg_install_snapshot, 1, 2, r.current_term)
	bad.snap_len = RAFT_SNAPSHOT_LIMIT + 1
	u64_set_int(bad.prev_log_index, 1)
	raft_on_msg(r, bad, 1, out)
	assert_equal(0, out.length)
	assert_equal(0, raft_snap_base(r))
	raft_msg_free(bad)
	raft_tick(r, 30001, out)
	stream_drop(out)
	assert_equal(0, cast(int, r.incoming_file))
	assert_equal(0, cast(int, r.incoming_snapshot))
	# Correct per-chunk CRC cannot bypass the end-to-end snapshot digest.
	u64_copy(m.term, r.current_term)
	m.chunk_total = 3
	m.chunk_crc = raft_snapshot_chunk_checksum(m)
	raft_on_msg(r, m, 30002, out)
	assert_equal(0, raft_has_pending_snapshot(r))
	assert_equal(0, cast(int, r.incoming_file))
	stream_drop(out)
	raft_msg_free(m)
	raft_free(r)
	free(path)

void test_stream_io_fault_sweep():
	for cut in range(1, 70):
		fake_fs* fs = fake_fs_new(cut)
		wal_recovery rep
		lsm* source = lsm_open_policy_with_ops(fs.ops, c"source", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(lsm_put(source, c"a", c"new", 3))
		assert1(lsm_put(source, c"b", c"new", 3))
		snapshot_file* s = lsm_export_file(source, c"scratch")
		assert1(cast(int, s) != 0)
		lsm_close(source)
		lsm* target = lsm_open_policy_with_ops(fs.ops, c"target", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(lsm_put(target, c"a", c"old", 3))
		assert1(lsm_put(target, c"b", c"old", 3))
		assert1(lsm_flush(target))
		fake_fs_fail_nth(fs, FAKE_FS_OP_ANY, cut, FAKE_FS_EIO)
		int installed = lsm_import_file(target, s)
		lsm_close(target)
		snapshot_file_free(s)
		for i in range(fs.rules.length): free(fs.rules[i])
		fs.rules.clear()
		prng* rng = prng_new(cut)
		fake_fs_crash(fs, rng)
		target = lsm_open_policy_with_ops(fs.ops, c"target", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep)
		assert1(cast(int, target) != 0)
		int len = 0
		char* a = lsm_get(target, c"a", &len)
		char* b = lsm_get(target, c"b", &len)
		assert1(a != 0 && b != 0)
		assert_strings_equal(a, b)
		assert1(strcmp(a, c"old") == 0 || strcmp(a, c"new") == 0)
		if (installed): assert_strings_equal(c"new", a)
		free(a)
		free(b)
		lsm_close(target)
		prng_free(rng)
		fake_fs_free(fs)


void test_stream_durable_application_barrier():
	char* source_path = stream_path(c"_apply_source")
	char* target_path = stream_path(c"_apply_target")
	stream_clean(source_path)
	stream_clean(target_path)
	lsm* source = lsm_open(source_path, 100000)
	u64* term = u64_new_int(1)
	lsm_batch* batch = lsm_batch_new()
	lsm_batch_put(batch, c"key", c"value", 5)
	assert_equal(APPLY_COMMITTED, durable_apply_commit(source, 1, term, c"request", batch, c"result", 6))
	lsm_batch_free(batch)
	snapshot_file* s = lsm_export_file(source, source_path)
	assert1(cast(int, s) != 0)
	lsm_close(source)
	for mismatch in range(2):
		stream_clean(target_path)
		lsm* target = lsm_open(target_path, 100000)
		assert1(lsm_put(target, c"old", c"preserved", 9))
		assert1(lsm_flush(target))
		raft* r = stream_node(2, 1)
		r.pending_snap_file = snapshot_file_retain(s)
		r.pending_snap_len = s.length
		u64_set_int(r.pending_snap_index, 1)
		u64_set_int(r.snap_last_term, 1 + mismatch)
		assert_equal(mismatch == 0, durable_apply_install_pending(r, target))
		assert_equal(mismatch, raft_has_pending_snapshot(r))
		assert_equal(mismatch, lsm_failed(target))
		if (mismatch == 0):
			char* result = 0
			int length = 0
			assert_equal(LSM_GET_FOUND, durable_apply_result(target, c"request", &result, &length))
			assert_strings_equal(c"result", result)
			free(result)
		raft_free(r)
		lsm_close(target)
		if (mismatch):
			target = lsm_open(target_path, 100000)
			int length = 0
			char* preserved = lsm_get(target, c"old", &length)
			assert_strings_equal(c"preserved", preserved)
			free(preserved)
			assert_equal(0, durable_apply_position(target, term))
			lsm_close(target)
	snapshot_file_free(s)
	u64_free(term)
	stream_clean(source_path)
	stream_clean(target_path)
	free(source_path)
	free(target_path)
