# wbuild: x64 timeout=60000
import lib.testing
import lib.time
import libs.standard.distributed.raft_tcp


raft* chunk_node(int id, int peer):
	list[int] peers = new list[int]
	peers.push(peer)
	raft* r = raft_new(id, peers, 100, 200, 20, id)
	u64_set_int(r.current_term, 1)
	return r


void chunk_drop(list[raft_msg*] messages):
	for i in range(messages.length): raft_msg_free(messages[i])
	messages.clear()


raft_msg* chunk_wire(raft_msg* m):
	int size = raft_wire_size(m)
	assert1(size < rt_max_frame())
	char* wire = cast(char*, malloc(size))
	raft_wire_encode(m, wire)
	assert1(cast(int, raft_wire_decode(wire, size - 1)) == 0)
	raft_msg* copy = raft_wire_decode(wire, size)
	assert1(cast(int, copy) != 0)
	free(wire)
	return copy


void test_large_restartable_snapshot():
	raft* leader = chunk_node(1, 2)
	raft* follower = chunk_node(2, 1)
	leader.state = raft_leader
	leader.log.push(raft_entry_new(leader.current_term, c"", 0))
	u64_set_int(leader.commit_index, 1)
	u64_set_int(leader.last_applied, 1)
	int length = rt_max_frame() + 8197
	char* data = cast(char*, malloc(length))
	for i in range(length): data[i] = i % 251
	assert_equal(1, raft_take_snapshot(leader, data, length))
	assert_equal(0, raft_take_snapshot(leader, data, RAFT_SNAPSHOT_LIMIT + 1))
	list[raft_msg*] out = new list[raft_msg*]
	list[raft_msg*] replies = new list[raft_msg*]
	int restarted = 0
	int corrupted = 0
	int steps = 0
	while (raft_has_pending_snapshot(follower) == 0 && steps < 100):
		raft_msg* source = raft_make_peer_msg(leader, 2)
		raft_msg* chunk = chunk_wire(source)
		raft_msg_free(source)
		assert_equal(raft_msg_snapshot_chunk, chunk.type)
		if (corrupted == 0):
			chunk.snap_data[0] = chunk.snap_data[0] ^ 1
			raft_on_msg(follower, chunk, steps, replies)
			assert_equal(0, replies.length)
			assert1(cast(int, follower.incoming_snapshot) == 0)
			chunk.snap_data[0] = chunk.snap_data[0] ^ 1
			corrupted = 1
		if (steps == 3 && restarted == 0):
			raft_free(follower)
			follower = chunk_node(2, 1)
			restarted = 1
		raft_on_msg(follower, chunk, steps, replies)
		# Repeated delivery does not append twice or advance beyond total.
		if (steps == 1): raft_on_msg(follower, chunk, steps, replies)
		raft_msg_free(chunk)
		for i in range(replies.length):
			raft_msg* ack = chunk_wire(replies[i])
			raft_on_msg(leader, ack, steps, out)
			raft_msg_free(ack)
		chunk_drop(replies)
		chunk_drop(out)
		steps = steps + 1
	assert1(steps < 100)
	assert_equal(length, follower.pending_snap_len)
	for i in range(length): assert_equal(data[i] & 255, follower.pending_snap_data[i] & 255)
	assert1(cast(int, follower.incoming_snapshot) == 0)
	assert_equal(2, u64_to_int(leader.next_index[2]))
	free(data)
	raft_free(leader)
	raft_free(follower)


void test_partial_frame_reconnect():
	rt_peer* p = new rt_peer(2, 0, -1, string_new_sized(32), new list[int], 3)
	string_append_bytes(p.out, c"suffixNEXT", 10)
	p.frame_lens.push(9)
	p.frame_lens.push(4)
	rt_peer_disconnect(p)
	assert_equal(0, p.head_sent)
	assert_equal(4, p.out.length)
	for i in range(4): assert_equal(p.out.data[i], c"NEXT"[i])
	string_free(p.out)
	list_free[int](p.frame_lens)
	free(p)


void test_tcp_large_snapshot_with_slow_receiver_and_control_traffic():
	int port = 25000 + __word_size__ * 100
	raft_tcp* sender = raft_tcp_new(1, port)
	raft_tcp* receiver = raft_tcp_new(2, port + 1)
	assert1(cast(int, sender) != 0 && cast(int, receiver) != 0)
	raft_tcp_add_peer(sender, 2, port + 1)
	raft_tcp_add_peer(receiver, 1, port)
	raft_tcp_set_max_pending(sender, 65536)
	raft_tcp_set_max_pending(receiver, 65536)
	receiver.max_inbox_messages = 2
	receiver.max_inbox_bytes = 65536
	raft* leader = chunk_node(1, 2)
	raft* follower = chunk_node(2, 1)
	leader.state = raft_leader
	leader.log.push(raft_entry_new(leader.current_term, c"", 0))
	u64_set_int(leader.commit_index, 1)
	u64_set_int(leader.last_applied, 1)
	int length = rt_max_frame() + 7
	char* data = cast(char*, malloc(length))
	mem_fill[char](data, 'S', length)
	assert1(raft_take_snapshot(leader, data, length))
	int controls = 0
	int complete = 0
	int retry = time_monotonic_ms()
	for tick in range(100000):
		int now = time_monotonic_ms()
		if (mono_expired(now, retry)):
			retry = mono_deadline(now, 200)
			raft_msg* message = raft_make_peer_msg(leader, 2)
			raft_tcp_send(sender, message)
			raft_msg_free(message)
			# Concurrent log heartbeat traffic stays schedulable between
			# chunks; it cannot install partial snapshot bytes.
			message = raft_msg_new(raft_msg_append, 1, 2, leader.current_term)
			raft_tcp_send(sender, message)
			raft_msg_free(message)
		if (tick % 100 == 0): sleep_ms(1)
		raft_tcp_pump(sender)
		if (tick % 5 == 0): raft_tcp_pump(receiver)
		assert1(raft_tcp_pending_bytes(sender, 2) <= 65536)
		assert1(receiver.inbox.length <= 2 && receiver.inbox_bytes <= 65536)
		if (tick % 5 == 0):
			raft_msg* message = raft_tcp_recv(receiver)
			if (cast(int, message) != 0):
				if (message.type == raft_msg_append): controls = controls + 1
				list[raft_msg*] replies = new list[raft_msg*]
				raft_on_msg(follower, message, tick, replies)
				raft_msg_free(message)
				for i in range(replies.length): raft_tcp_send(receiver, replies[i])
				chunk_drop(replies)
		raft_msg* ack = raft_tcp_recv(sender)
		if (cast(int, ack) != 0):
			list[raft_msg*] next = new list[raft_msg*]
			raft_on_msg(leader, ack, tick, next)
			raft_msg_free(ack)
			for i in range(next.length): raft_tcp_send(sender, next[i])
			chunk_drop(next)
		if (raft_has_pending_snapshot(follower) && u64_to_int(leader.next_index[2]) == 2):
			complete = 1
			break
	assert1(complete)
	assert1(controls > 0)
	assert_equal(length, follower.pending_snap_len)
	assert_equal(raft_snapshot_checksum(data, length), raft_snapshot_checksum(follower.pending_snap_data, length))
	free(data)
	raft_free(leader)
	raft_free(follower)
	raft_tcp_free(sender)
	raft_tcp_free(receiver)
