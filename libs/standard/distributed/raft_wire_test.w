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


# Bytewise blob/command comparison: values may be binary (embedded
# zeros and other non-text bytes legal), so strcmp-style helpers must
# never touch them.
void rw_assert_blob(char* want, int want_len, char* got, int got_len):
	assert_equal(want_len, got_len)
	int i = 0
	while (i < want_len):
		assert_equal(want[i] & 255, got[i] & 255)
		i = i + 1


void test_vote_req_roundtrip():
	u64* term = u64_new_int(7)
	raft_msg* m = raft_msg_new(raft_msg_vote_req(), 1, 2, term)
	u64_set_int(m.last_log_index, 42)
	u64_set_int(m.last_log_term, 6)
	assert_equal(34, raft_wire_size(m))
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
	assert_equal(19, raft_wire_size(m))
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
	m.entries.push(raft_entry_new(t1, c"P\tk1\tv1", 7))
	m.entries.push(raft_entry_new(t2, c"D\tk2", 4))
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


# Binary-safe commands (issue #315): a command carrying an embedded
# NUL, a tab (0x09) and a high byte (0xFF) must survive encode/decode
# byte-exactly -- raft_entry.command_len (never strlen) is
# authoritative on the wire, so none of those bytes can be mistaken
# for a terminator or truncate the payload.
void test_binary_command_roundtrip():
	u64* term = u64_new_int(5)
	raft_msg* m = raft_msg_new(raft_msg_append(), 1, 2, term)
	u64_set_int(m.prev_log_index, 3)
	u64_set_int(m.prev_log_term, 4)
	u64_set_int(m.leader_commit, 3)
	char* cmd = malloc(6)
	cmd[0] = 'A'
	cmd[1] = 0
	cmd[2] = 9
	cmd[3] = 255
	cmd[4] = 'Z'
	cmd[5] = 0
	u64* t = u64_new_int(5)
	m.entries.push(raft_entry_new(t, cmd, 6))
	assert_equal(17 + 28 + 8 + 4 + 6, raft_wire_size(m))
	raft_msg* out = rw_roundtrip(m)
	assert_equal(1, out.entries.length)
	raft_entry* e = out.entries[0]
	assert_equal(6, e.command_len)
	rw_assert_blob(cmd, 6, e.command, e.command_len)
	raft_msg_free(m)
	raft_msg_free(out)
	u64_free(t)
	u64_free(term)
	free(cmd)


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
	assert_equal(1, buf[17] & 255)    # granted (offset unchanged)
	assert_equal(0, buf[18] & 255)    # prevote flag, clear by default
	free(buf)
	raft_msg_free(m)
	u64_free(term)


void test_prevote_flag_roundtrip():
	# vote_req with the flag set: last byte of the 34-byte layout
	u64* term = u64_new_int(9)
	raft_msg* m = raft_msg_new(raft_msg_vote_req(), 1, 2, term)
	m.prevote = 1
	u64_set_int(m.last_log_index, 3)
	u64_set_int(m.last_log_term, 2)
	assert_equal(34, raft_wire_size(m))
	char* buf = malloc(34)
	raft_wire_encode(m, buf)
	assert_equal(1, buf[33] & 255)
	free(buf)
	raft_msg* out = rw_roundtrip(m)
	assert_equal(1, out.prevote)
	assert_equal(3, raft_u64_as_int(out.last_log_index))
	assert_equal(2, raft_u64_as_int(out.last_log_term))
	raft_msg_free(out)
	# and clear
	m.prevote = 0
	out = rw_roundtrip(m)
	assert_equal(0, out.prevote)
	raft_msg_free(m)
	raft_msg_free(out)
	u64_free(term)
	# vote_reply set...
	u64* t2 = u64_new_int(4)
	raft_msg* rep = raft_msg_new(raft_msg_vote_reply(), 2, 1, t2)
	rep.vote_granted = 1
	rep.prevote = 1
	assert_equal(19, raft_wire_size(rep))
	char* rbuf = malloc(19)
	raft_wire_encode(rep, rbuf)
	assert_equal(1, rbuf[17] & 255)   # granted keeps its offset
	assert_equal(1, rbuf[18] & 255)   # prevote trails it
	free(rbuf)
	raft_msg* rout = rw_roundtrip(rep)
	assert_equal(1, rout.prevote)
	assert_equal(1, rout.vote_granted)
	raft_msg_free(rout)
	# ...and clear
	rep.prevote = 0
	rout = rw_roundtrip(rep)
	assert_equal(0, rout.prevote)
	assert_equal(1, rout.vote_granted)
	raft_msg_free(rep)
	raft_msg_free(rout)
	u64_free(t2)


void test_decode_rejects_malformed():
	u64* term = u64_new_int(5)
	raft_msg* m = raft_msg_new(raft_msg_append(), 1, 2, term)
	u64* t = u64_new_int(5)
	m.entries.push(raft_entry_new(t, c"P\ta\tb", 5))
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


# ---- install_snapshot (type 4) ----------------------------------------------------


void test_install_snapshot_roundtrip():
	u64* term = u64_new_int(6)
	raft_msg* m = raft_msg_new(raft_msg_install_snapshot(), 1, 3, term)
	u64_set_int(m.prev_log_index, 10)
	u64_set_int(m.prev_log_term, 5)
	u64_set_int(m.leader_commit, 12)
	# binary blob with embedded zeros and a high byte
	char* blob = malloc(6)
	blob[0] = 83
	blob[1] = 0
	blob[2] = 78
	blob[3] = 0
	blob[4] = 65
	blob[5] = 255
	m.snap_data = blob
	m.snap_len = 6
	assert_equal(17 + 28 + 6, raft_wire_size(m))
	raft_msg* out = rw_roundtrip(m)
	assert_equal(raft_msg_install_snapshot(), out.type)
	assert_equal(1, out.from)
	assert_equal(3, out.to)
	assert_equal(6, raft_u64_as_int(out.term))
	assert_equal(10, raft_u64_as_int(out.prev_log_index))
	assert_equal(5, raft_u64_as_int(out.prev_log_term))
	assert_equal(12, raft_u64_as_int(out.leader_commit))
	rw_assert_blob(blob, 6, out.snap_data, out.snap_len)
	raft_msg_free(m)
	raft_msg_free(out)
	u64_free(term)


void test_install_snapshot_empty_blob():
	u64* term = u64_new_int(2)
	raft_msg* m = raft_msg_new(raft_msg_install_snapshot(), 2, 1, term)
	u64_set_int(m.prev_log_index, 4)
	u64_set_int(m.prev_log_term, 1)
	u64_set_int(m.leader_commit, 4)
	assert_equal(17 + 28, raft_wire_size(m))
	raft_msg* out = rw_roundtrip(m)
	assert_equal(raft_msg_install_snapshot(), out.type)
	assert_equal(4, raft_u64_as_int(out.prev_log_index))
	assert_equal(1, raft_u64_as_int(out.prev_log_term))
	assert_equal(0, out.snap_len)
	raft_msg_free(m)
	raft_msg_free(out)
	u64_free(term)


void test_install_snapshot_malformed():
	u64* term = u64_new_int(3)
	raft_msg* m = raft_msg_new(raft_msg_install_snapshot(), 1, 2, term)
	u64_set_int(m.prev_log_index, 9)
	u64_set_int(m.prev_log_term, 2)
	char* blob = malloc(4)
	blob[0] = 1
	blob[1] = 0
	blob[2] = 2
	blob[3] = 3
	m.snap_data = blob
	m.snap_len = 4
	int size = raft_wire_size(m)
	char* buf = malloc(size)
	raft_wire_encode(m, buf)
	# truncated blob: snap_len promises more bytes than the buffer has
	assert_equal(0, cast(int, raft_wire_decode(buf, size - 1)))
	# shorter than the fixed post-header fields
	assert_equal(0, cast(int, raft_wire_decode(buf, 17 + 27)))
	# trailing garbage byte
	char* big = malloc(size + 1)
	int i = 0
	while (i < size):
		big[i] = buf[i]
		i = i + 1
	big[size] = 7
	assert_equal(0, cast(int, raft_wire_decode(big, size + 1)))
	# huge snap_len overrunning the buffer
	raft_wire_u32(buf + 17 + 24, 100000)
	assert_equal(0, cast(int, raft_wire_decode(buf, size)))
	# negative snap_len
	raft_wire_u32(buf + 17 + 24, 0 - 4)
	assert_equal(0, cast(int, raft_wire_decode(buf, size)))
	free(big)
	free(buf)
	raft_msg_free(m)
	u64_free(term)


void test_type4_known_type5_rejected():
	# the unknown-type guard moved: 4 (install_snapshot) is now a KNOWN
	# type, 5 is the first unknown one
	u64* term = u64_new_int(1)
	raft_msg* m = raft_msg_new(raft_msg_install_snapshot(), 1, 2, term)
	int size = raft_wire_size(m)
	char* buf = malloc(size)
	raft_wire_encode(m, buf)
	assert_equal(4, buf[0] & 255)
	raft_msg* ok = raft_wire_decode(buf, size)
	assert1(cast(int, ok) != 0)
	assert_equal(raft_msg_install_snapshot(), ok.type)
	raft_msg_free(ok)
	buf[0] = 5
	assert_equal(0, cast(int, raft_wire_decode(buf, size)))
	free(buf)
	raft_msg_free(m)
	u64_free(term)
