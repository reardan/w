# wbuild: x64
import lib.testing
import libs.standard.distributed.raft_wire


raft_msg* rw_roundtrip(raft_msg* m):
	int size = raft_wire_size(m)
	char* buf = malloc(size)
	raft_wire_encode(m, buf)
	raft_msg* out = raft_wire_decode(buf, size)
	assert1(cast(int, out) != 0)
	free(buf)
	return out


void test_vote_req_roundtrip():
	u64* term = u64_new_int(7)
	raft_msg* m = raft_msg_new(raft_msg_vote_req(), 1, 2, term)
	u64_set_int(m.last_log_index, 42)
	u64_set_int(m.last_log_term, 6)
	assert_equal(33, raft_wire_size(m))
	raft_msg* out = rw_roundtrip(m)
	assert_equal(raft_msg_vote_req(), out.type)
	assert_equal(1, out.from)
	assert_equal(2, out.to)
	assert_equal(7, raft_u64_as_int(out.term))
	assert_equal(42, raft_u64_as_int(out.last_log_index))
	assert_equal(6, raft_u64_as_int(out.last_log_term))
	raft_msg_free(m)
	raft_msg_free(out)
	u64_free(term)


void test_vote_reply_roundtrip():
	u64* term = u64_new_int(3)
	raft_msg* m = raft_msg_new(raft_msg_vote_reply(), 5, 1, term)
	m.vote_granted = 1
	assert_equal(18, raft_wire_size(m))
	raft_msg* out = rw_roundtrip(m)
	assert_equal(1, out.vote_granted)
	assert_equal(5, out.from)
	raft_msg_free(m)
	raft_msg_free(out)
	u64_free(term)


void test_append_roundtrip_with_entries():
	u64* term = u64_new_int(9)
	raft_msg* m = raft_msg_new(raft_msg_append(), 3, 4, term)
	u64_set_int(m.prev_log_index, 10)
	u64_set_int(m.prev_log_term, 8)
	u64_set_int(m.leader_commit, 10)
	u64* t1 = u64_new_int(8)
	u64* t2 = u64_new_int(9)
	m.entries.push(raft_entry_new(t1, c"P\tk1\tv1"))
	m.entries.push(raft_entry_new(t2, c"D\tk2"))
	raft_msg* out = rw_roundtrip(m)
	assert_equal(2, out.entries.length)
	raft_entry* e0 = out.entries[0]
	raft_entry* e1 = out.entries[1]
	assert_equal(8, raft_u64_as_int(e0.term))
	assert_strings_equal(c"P\tk1\tv1", e0.command)
	assert_equal(9, raft_u64_as_int(e1.term))
	assert_strings_equal(c"D\tk2", e1.command)
	assert_equal(10, raft_u64_as_int(out.leader_commit))
	raft_msg_free(m)
	raft_msg_free(out)
	u64_free(t1)
	u64_free(t2)
	u64_free(term)


void test_append_heartbeat_empty_entries():
	u64* term = u64_new_int(2)
	raft_msg* m = raft_msg_new(raft_msg_append(), 1, 3, term)
	assert_equal(17 + 28, raft_wire_size(m))
	raft_msg* out = rw_roundtrip(m)
	assert_equal(0, out.entries.length)
	raft_msg_free(m)
	raft_msg_free(out)
	u64_free(term)


void test_append_reply_roundtrip():
	u64* term = u64_new_int(4)
	raft_msg* m = raft_msg_new(raft_msg_append_reply(), 2, 1, term)
	m.success = 1
	u64_set_int(m.match_index, 17)
	assert_equal(26, raft_wire_size(m))
	raft_msg* out = rw_roundtrip(m)
	assert_equal(1, out.success)
	assert_equal(17, raft_u64_as_int(out.match_index))
	raft_msg_free(m)
	raft_msg_free(out)
	u64_free(term)


void test_layout_bytes():
	# vote_reply from 258 (0x102): type byte then from as le32
	u64* term = u64_new_int(1)
	raft_msg* m = raft_msg_new(raft_msg_vote_reply(), 258, 1, term)
	m.vote_granted = 1
	char* buf = malloc(raft_wire_size(m))
	raft_wire_encode(m, buf)
	assert_equal(raft_msg_vote_reply(), buf[0] & 255)
	assert_equal(2, buf[1] & 255)
	assert_equal(1, buf[2] & 255)
	assert_equal(0, buf[3] & 255)
	assert_equal(1, buf[5] & 255)     # to = 1
	assert_equal(1, buf[9] & 255)     # term = 1, low u64 byte
	assert_equal(0, buf[16] & 255)    # term high byte
	assert_equal(1, buf[17] & 255)    # granted
	free(buf)
	raft_msg_free(m)
	u64_free(term)


void test_decode_rejects_malformed():
	u64* term = u64_new_int(5)
	raft_msg* m = raft_msg_new(raft_msg_append(), 1, 2, term)
	u64* t = u64_new_int(5)
	m.entries.push(raft_entry_new(t, c"P\ta\tb"))
	int size = raft_wire_size(m)
	char* buf = malloc(size)
	raft_wire_encode(m, buf)
	# short buffer
	assert_equal(0, cast(int, raft_wire_decode(buf, size - 1)))
	assert_equal(0, cast(int, raft_wire_decode(buf, 16)))
	# trailing garbage
	char* big = malloc(size + 1)
	int i = 0
	while (i < size):
		big[i] = buf[i]
		i = i + 1
	big[size] = 99
	assert_equal(0, cast(int, raft_wire_decode(big, size + 1)))
	# unknown type
	buf[0] = 42
	assert_equal(0, cast(int, raft_wire_decode(buf, size)))
	buf[0] = raft_msg_append()
	# entry cmd_len overrunning the buffer
	raft_wire_u32(buf + 17 + 28 + 8, 1000)
	assert_equal(0, cast(int, raft_wire_decode(buf, size)))
	free(big)
	free(buf)
	raft_msg_free(m)
	u64_free(t)
	u64_free(term)
