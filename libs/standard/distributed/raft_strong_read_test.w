# wbuild: x64
import lib.testing
import libs.standard.distributed.raft_wire


raft* read_node(int id):
	list[int] peers = new list[int]
	for i in range(1, 4):
		if (i != id): peers.push(i)
	return raft_new(id, peers, 100, 200, 20, id)


void read_drop(list[raft_msg*] messages):
	for i in range(messages.length): raft_msg_free(messages[i])
	messages.clear()


# Exercise actual request/reply codecs, including malformed truncation.
raft_msg* read_wire(raft_msg* m):
	int n = raft_wire_size(m)
	char* buf = cast(char*, malloc(n))
	raft_wire_encode(m, buf)
	assert1(cast(int, raft_wire_decode(buf, n - 1)) == 0)
	raft_msg* copy = raft_wire_decode(buf, n)
	assert1(cast(int, copy) != 0)
	free(buf)
	return copy


void test_quorum_application_and_stale_replies():
	raft* leader = read_node(1)
	raft* follower = read_node(2)
	list[raft_msg*] out = new list[raft_msg*]
	list[raft_msg*] replies = new list[raft_msg*]
	u64_set_int(leader.current_term, 1)
	leader.state = raft_leader
	int index = 0
	# A role probe and an old-term commit are insufficient.
	assert_equal(0, raft_read_begin(leader, 0, 100, out))
	u64* old = u64_new()
	leader.log.push(raft_entry_new(old, c"", 0))
	u64_set_int(leader.commit_index, 1)
	assert_equal(0, raft_read_begin(leader, 0, 100, out))
	u64_set_int(leader.log[0].term, 1)
	int token = raft_read_begin(leader, 0, 100, out)
	assert1(token > 0)
	assert_equal(0, raft_read_poll(leader, token, 1, 1, &index))
	raft_msg* probe = read_wire(out[0])
	raft_on_msg(follower, probe, 1, replies)
	raft_msg_free(probe)
	assert_equal(1, replies.length)
	raft_msg* ack = read_wire(replies[0])
	raft_on_msg(leader, ack, 2, out)
	raft_on_msg(leader, ack, 2, out) # dedup
	assert_equal(1, leader.read_acks.length)
	assert_equal(0, raft_read_poll(leader, token, 3, 0, &index))
	# A concurrent later write does not move the confirmed barrier.
	leader.log.push(raft_entry_new(leader.current_term, c"later", 5))
	u64_set_int(leader.commit_index, 2)
	assert_equal(1, raft_read_poll(leader, token, 4, 1, &index))
	assert_equal(1, index)
	read_drop(out)
	int next = raft_read_begin(leader, 5, 10, out)
	raft_on_msg(leader, ack, 6, out) # delayed reply to previous read
	assert_equal(0, raft_read_poll(leader, next, 7, 2, &index))
	assert_equal(-1, raft_read_poll(leader, next, 15, 2, &index))
	read_drop(out)
	# Higher-term leadership change invalidates a waiting read.
	next = raft_read_begin(leader, 16, 100, out)
	u64_set_int(ack.term, 2)
	raft_on_msg(leader, ack, 17, out)
	assert_equal(raft_follower, leader.state)
	assert_equal(-1, raft_read_poll(leader, next, 18, 2, &index))
	raft_msg_free(ack)
	read_drop(out)
	read_drop(replies)
	u64_free(old)
	raft_free(leader)
	raft_free(follower)


void test_partitioned_leader_and_logged_baseline():
	# Checked sequential history: write i, then read must cover i. The
	# third voter is partitioned. Without voter 2, no read completes.
	raft* leader = read_node(1)
	raft* follower = read_node(2)
	list[raft_msg*] out = new list[raft_msg*]
	list[raft_msg*] replies = new list[raft_msg*]
	u64_set_int(leader.current_term, 1)
	leader.state = raft_leader
	for i in range(1, 21):
		leader.log.push(raft_entry_new(leader.current_term, c"increment", 9))
		u64_set_int(leader.commit_index, i)
		int now = i * 100
		int token = raft_read_begin(leader, now, 50, out)
		int index = 0
		assert_equal(0, raft_read_poll(leader, token, now + 1, i, &index))
		if (i % 3 == 0):
			assert_equal(-1, raft_read_poll(leader, token, now + 50, i, &index))
		else:
			raft_on_msg(follower, out[0], now + 2, replies)
			raft_on_msg(leader, replies[0], now + 3, out)
			assert_equal(1, raft_read_poll(leader, token, now + 4, i, &index))
			assert_equal(i, index)
		read_drop(out)
		read_drop(replies)
	raft_free(leader)
	raft_free(follower)


import lib.fake_fs
import libs.standard.distributed.raft_wal
import libs.standard.distributed.durable_apply


struct read_history:
	list[raft*] nodes
	list[raft_wal*] logs
	list[lsm*] stores
	list[fake_fs*] files
	list[raft_msg*] network
	int isolated


read_history* read_history_new():
	read_history* h = new read_history(new list[raft*], new list[raft_wal*], new list[lsm*], new list[fake_fs*], new list[raft_msg*], 0)
	for id in range(1, 4):
		raft* node = read_node(id)
		raft_set_noop_on_win(node, 1)
		h.nodes.push(node)
		fake_fs* fs = fake_fs_new(id)
		h.files.push(fs)
		wal_recovery rep
		h.logs.push(raft_wal_open_policy_with_ops(fs.ops, c"raft", WAL_RECOVER_STRICT_TRUNCATE, &rep))
		h.stores.push(lsm_open_policy_with_ops(fs.ops, c"app", 100000, WAL_RECOVER_STRICT_TRUNCATE, &rep))
	return h


int read_history_value(lsm* store):
	int len = 0
	char* value = lsm_get(store, c"counter", &len)
	if (value == 0): return 0
	int count = atoi(value)
	free(value)
	return count


# Persistence gates every message. Application batches publish only
# committed entries; no response is inferred from local log append.
void read_history_apply(read_history* h, int id):
	raft* node = h.nodes[id - 1]
	lsm* store = h.stores[id - 1]
	while (raft_pending_apply(node)):
		raft_entry* e = raft_pop_apply(node)
		lsm_batch* batch = lsm_batch_new()
		if (e.command_len == 1 && e.command[0] == 'I'):
			char* count = itoa(read_history_value(store) + 1)
			lsm_batch_put(batch, c"counter", count, strlen(count))
			free(count)
		assert_equal(APPLY_COMMITTED, durable_apply_commit(store, u64_to_int(node.last_applied), e.term, cast(char*, 0), batch, c"", 0))
		lsm_batch_free(batch)


void read_history_publish(read_history* h, int id, list[raft_msg*] staged):
	assert_equal(IO_OK, raft_wal_persist_release(h.logs[id - 1], h.nodes[id - 1], staged, h.network))
	read_history_apply(h, id)


void read_history_deliver(read_history* h, int now):
	int steps = 0
	while (h.network.length > 0):
		assert1(steps < 1000)
		steps = steps + 1
		raft_msg* m = h.network[0]
		list_remove_at[raft_msg*](h.network, 0)
		if (m.from != h.isolated && m.to != h.isolated):
			list[raft_msg*] staged = new list[raft_msg*]
			raft_msg* decoded = read_wire(m)
			raft_on_msg(h.nodes[m.to - 1], decoded, now, staged)
			raft_msg_free(decoded)
			read_history_publish(h, m.to, staged)
		raft_msg_free(m)


void test_replicated_history_leader_change_and_logged_read():
	read_history* h = read_history_new()
	list[raft_msg*] staged = new list[raft_msg*]
	raft_start_election(h.nodes[0], 0, staged)
	read_history_publish(h, 1, staged)
	read_history_deliver(h, 1)
	assert_equal(raft_leader, h.nodes[0].state)
	assert1(raft_propose(h.nodes[0], c"I", 1, 2, staged))
	read_history_publish(h, 1, staged)
	read_history_deliver(h, 3)
	int token = raft_read_begin(h.nodes[0], 4, 50, staged)
	assert1(token > 0)
	read_history_publish(h, 1, staged)
	read_history_deliver(h, 5)
	u64* term = u64_new()
	int index = 0
	assert_equal(1, raft_read_poll(h.nodes[0], token, 6, durable_apply_position(h.stores[0], term), &index))
	assert_equal(1, read_history_value(h.stores[0]))
	# Isolate the old leader; node 2 wins with node 3 and commits another
	# increment. The old leader still THINKS it leads but cannot read.
	h.isolated = 1
	raft_start_election(h.nodes[1], 10, staged)
	read_history_publish(h, 2, staged)
	read_history_deliver(h, 11)
	assert_equal(raft_leader, h.nodes[1].state)
	assert1(raft_propose(h.nodes[1], c"I", 1, 12, staged))
	read_history_publish(h, 2, staged)
	read_history_deliver(h, 13)
	token = raft_read_begin(h.nodes[0], 14, 10, staged)
	assert1(token > 0)
	read_history_publish(h, 1, staged)
	read_history_deliver(h, 15)
	assert_equal(-1, raft_read_poll(h.nodes[0], token, 24, durable_apply_position(h.stores[0], term), &index))
	# Logged-read baseline: R commits after I, then ReadIndex returns the
	# same application value without appending another entry.
	assert1(raft_propose(h.nodes[1], c"R", 1, 25, staged))
	read_history_publish(h, 2, staged)
	read_history_deliver(h, 26)
	assert_equal(2, read_history_value(h.stores[1]))
	int length = raft_last_index(h.nodes[1])
	token = raft_read_begin(h.nodes[1], 27, 50, staged)
	read_history_publish(h, 2, staged)
	read_history_deliver(h, 28)
	assert_equal(1, raft_read_poll(h.nodes[1], token, 29, durable_apply_position(h.stores[1], term), &index))
	assert_equal(2, read_history_value(h.stores[1]))
	assert_equal(length, raft_last_index(h.nodes[1]))
	h.isolated = 0
	raft_tick(h.nodes[1], 60, staged)
	read_history_publish(h, 2, staged)
	read_history_deliver(h, 61)
	assert_equal(raft_follower, h.nodes[0].state)
	assert_equal(2, read_history_value(h.stores[0]))
	for i in range(3):
		raft_free(h.nodes[i])
		raft_wal_close(h.logs[i])
		lsm_close(h.stores[i])
		fake_fs_free(h.files[i])
	u64_free(term)
	free(h)
