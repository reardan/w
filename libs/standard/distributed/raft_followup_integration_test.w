# wbuild: x64
import lib.testing
import lib.fake_fs
import libs.standard.distributed.kv_state
import libs.standard.distributed.raft_wal
import libs.standard.distributed.durable_apply

struct followup_owner:
	fake_fs* files
	raft* node
	raft_wal* log
	lsm* store

followup_owner* followup_new(int id, int learner):
	fake_fs* files = fake_fs_new(id)
	list[int] voters = new list[int]
	if (learner): voters.push(1)
	raft* node = 0
	if (learner): node = raft_new_learner(id, voters, 100, 200, 20, id)
	else: node = raft_new(id, voters, 100, 200, 20, id)
	voters.free()
	raft_enable_snapshot_files(node, files.ops, c"scratch")
	wal_recovery recovery
	raft_wal* log = raft_wal_open_policy_with_ops(files.ops, c"log", WAL_RECOVER_STRICT_TRUNCATE, &recovery)
	lsm* store = lsm_open_policy_with_ops(files.ops, c"app", 1048576, WAL_RECOVER_STRICT_TRUNCATE, &recovery)
	assert1(cast(int, log) != 0 && cast(int, store) != 0)
	return new followup_owner(files, node, log, store)

void followup_free(followup_owner* owner):
	raft_free(owner.node)
	raft_wal_close(owner.log)
	lsm_close(owner.store)
	fake_fs_free(owner.files)
	free(owner)

void followup_drop(list[raft_msg*] messages):
	for i in range(messages.length): raft_msg_free(messages[i])
	messages.clear()

int followup_counter(lsm* store):
	int len = 0
	char* value = lsm_get(store, c"counter", &len)
	if (value == 0): return 0
	int count = atoi(value)
	free(value)
	return count

void followup_apply(followup_owner* owner):
	while (raft_has_pending_snapshot(owner.node) == 0 && raft_pending_apply(owner.node)):
		raft_entry* entry = raft_pop_apply(owner.node)
		lsm_batch* batch = lsm_batch_new()
		char* request = 0
		if (entry.command_len == 1 && entry.command[0] == 'I'):
			request = c"A"
			char* count = itoa(followup_counter(owner.store) + 1)
			lsm_batch_put(batch, c"counter", count, strlen(count))
			free(count)
			char* padding = cast(char*, malloc(65536))
			mem_fill[char](padding, 37, 65536)
			lsm_batch_put(batch, c"padding", padding, 65536)
			free(padding)
		int status = durable_apply_commit(owner.store, raft_u64_as_int(owner.node.last_applied), entry.term, request, batch, c"1", 1)
		assert1(status == APPLY_COMMITTED || status == APPLY_DUPLICATE)
		lsm_batch_free(batch)

void followup_publish(followup_owner* owner, list[raft_msg*] staged, list[raft_msg*] network):
	assert_equal(IO_OK, raft_wal_persist_release(owner.log, owner.node, staged, network))
	followup_apply(owner)

void followup_deliver(followup_owner* leader, followup_owner* learner, list[raft_msg*] network, int now):
	int steps = 0
	while (network.length > 0):
		assert1(steps < 100)
		steps = steps + 1
		raft_msg* message = network[0]
		list_remove_at[raft_msg*](network, 0)
		followup_owner* target = leader
		if (message.to == 2): target = learner
		list[raft_msg*] staged = new list[raft_msg*]
		raft_on_msg(target.node, message, now, staged)
		raft_msg_free(message)
		followup_publish(target, staged, network)
		staged.free()

void test_streamed_learner_recovery_promotion_and_read():
	followup_owner* leader = followup_new(1, 0)
	followup_owner* learner = followup_new(2, 1)
	list[raft_msg*] staged = new list[raft_msg*]
	list[raft_msg*] network = new list[raft_msg*]
	raft_set_noop_on_win(leader.node, 1)
	raft_start_election(leader.node, 0, staged)
	followup_publish(leader, staged, network)
	assert_equal(raft_leader, leader.node.state)
	assert1(raft_propose(leader.node, c"I", 1, 1, staged))
	followup_publish(leader, staged, network)
	assert1(raft_propose_add_learner(leader.node, 2, 2, staged))
	followup_publish(leader, staged, network)
	# The learner was offline while the leader compacted its committed log.
	followup_drop(network)
	assert_equal(0, raft_learner_ready(leader.node, 2))
	assert1(kv_take_snapshot_file(leader.node, leader.store, c"scratch"))
	assert1(leader.node.snap_len > RAFT_SNAPSHOT_CHUNK)
	followup_publish(leader, staged, network)
	network.push(raft_make_peer_msg(leader.node, 2))
	followup_deliver(leader, learner, network, 3)
	assert1(raft_has_pending_snapshot(learner.node))
	assert_equal(0, raft_is_voter(learner.node, 2))
	assert_equal(0, followup_counter(learner.store))
	assert1(raft_learner_ready(leader.node, 2))
	# Crash after the durable final ACK but before application publication.
	raft_free(learner.node)
	raft_wal_close(learner.log)
	lsm_close(learner.store)
	fake_fs_crash(learner.files, cast(prng*, 0))
	wal_recovery recovery
	learner.log = raft_wal_open_policy_with_ops(learner.files.ops, c"log", WAL_RECOVER_STRICT_TRUNCATE, &recovery)
	assert1(cast(int, learner.log) != 0)
	list[int] voters = new list[int]
	voters.push(1)
	learner.node = raft_wal_recover_learner(learner.log, 2, voters, 100, 200, 20, 2)
	voters.free()
	assert1(cast(int, learner.node) != 0)
	learner.store = lsm_open_policy_with_ops(learner.files.ops, c"app", 1048576, WAL_RECOVER_STRICT_TRUNCATE, &recovery)
	assert1(cast(int, learner.store) != 0)
	assert_equal(0, raft_is_voter(learner.node, 2))
	assert1(cast(int, learner.node.pending_snap_file) != 0)
	assert1(durable_apply_install_pending(learner.node, learner.store))
	assert1(durable_apply_snapshot_matches(learner.store, learner.node.snap_last_index, learner.node.snap_last_term))
	assert_equal(1, followup_counter(learner.store))
	char* result = 0
	int len = 0
	assert_equal(LSM_GET_FOUND, durable_apply_result(learner.store, c"A", &result, &len))
	assert_equal(0, strcmp(result, c"1"))
	free(result)
	# Promotion invalidates the old read context and requires the new quorum.
	int token = raft_read_begin(leader.node, 4, 100, staged)
	assert1(token > 0)
	followup_drop(staged)
	assert1(raft_propose_promote_learner(leader.node, 2, 5, staged))
	int index = 0
	assert_equal(-1, raft_read_poll(leader.node, token, 6, 3, &index))
	followup_publish(leader, staged, network)
	followup_deliver(leader, learner, network, 7)
	assert1(raft_is_voter(learner.node, 2))
	assert_equal(0, raft_config_pending(leader.node))
	raft_tick(leader.node, 30, staged)
	followup_publish(leader, staged, network)
	followup_deliver(leader, learner, network, 31)
	# A lost client response can be retried after streamed recovery/promotion.
	assert1(raft_propose(leader.node, c"I", 1, 32, staged))
	followup_publish(leader, staged, network)
	followup_deliver(leader, learner, network, 33)
	token = raft_read_begin(leader.node, 34, 100, staged)
	assert1(token > 0)
	u64* term = u64_new()
	int applied = durable_apply_position(leader.store, term)
	assert_equal(0, raft_read_poll(leader.node, token, 35, applied, &index))
	followup_publish(leader, staged, network)
	followup_deliver(leader, learner, network, 36)
	assert_equal(1, raft_read_poll(leader.node, token, 37, applied, &index))
	assert_equal(1, followup_counter(leader.store))
	assert_equal(1, followup_counter(learner.store))
	u64_free(term)
	staged.free()
	network.free()
	followup_free(leader)
	followup_free(learner)

# Checksummed records can still carry invalid snapshot metadata. Both formats
# must fail recovery before an invalid index or learner identity reaches Raft.
void test_snapshot_wal_rejects_invalid_boundaries_and_members():
	for variant in range(4):
		fake_fs* files = fake_fs_new(variant)
		wal_recovery recovery
		wal* log = wal_open_policy_with_ops(files.ops, c"invalid", WAL_RECOVER_STRICT_TRUNCATE, &recovery)
		char* header = cast(char*, malloc(37))
		mem_fill[char](header, 0, 37)
		int streamed = variant % 2
		header[0] = raft_wal_tag_snapshot
		if (streamed): header[0] = raft_wal_tag_stream_begin
		u64* index = u64_new_int(1)
		if (variant < 2): index.w2 = 1
		u64_save_le(header + 1, index)
		u64_set_int(index, 1)
		u64_save_le(header + 9, index)
		store_le32(header + 17, 2)
		store_le32(header + 21, 1)
		store_le32(header + 25, -3)
		# -2 is learner ID 1, conflicting with the voter ID 1 above.
		if (variant >= 2): store_le32(header + 25, -2)
		store_le32(header + 29, 1)
		if (streamed):
			store_le32(header + 33, raft_snapshot_checksum(c"X", 1))
			assert1(wal_append(log, header, 37))
			header[0] = raft_wal_tag_stream_chunk
			store_le32(header + 1, 0)
			header[5] = 'X'
			assert1(wal_append(log, header, 6))
			header[0] = raft_wal_tag_stream_end
			assert1(wal_append(log, header, 1))
		else:
			header[33] = 'X'
			assert1(wal_append(log, header, 34))
		assert1(wal_sync(log))
		wal_close(log)
		raft_wal* restored = raft_wal_open_policy_with_ops(files.ops, c"invalid", WAL_RECOVER_STRICT_TRUNCATE, &recovery)
		assert_equal(0, cast(int, restored))
		u64_free(index)
		free(header)
		fake_fs_free(files)
