/*
Wire format for raft messages (docs/projects/distributed.md, phase
4c) — the frozen byte encoding raft_tcp.w frames over sockets.

Layout, all little-endian, u64 fields via u64_save_le:
  common:        type u8, from u32, to u32, term u64
  vote_req:      + last_log_index u64, last_log_term u64, prevote u8
  vote_reply:    + granted u8, prevote u8
  append:        + prev_log_index u64, prev_log_term u64,
                   leader_commit u64, entry_count u32,
                   then per entry: term u64, cmd_len u32, cmd bytes
                   (opaque bytes, embedded NUL legal; cmd_len is
                   raft_entry.command_len, never strlen — no NUL on
                   the wire either way)
  append_reply:  + success u8, match_index u64
  install_snapshot: + prev_log_index u64 (snapshot last index),
                   prev_log_term u64 (snapshot last term),
                   leader_commit u64, snap_len u32, blob bytes

The prevote flag byte (raft.w's pre-vote rounds, §9.6) trails each
vote layout so the earlier fields keep their offsets; it is 0 on every
real vote message. Append layouts are untouched.

install_snapshot (raft.w's §7 log compaction) reuses the append field
names per raft.w's convention: prev_log_index/prev_log_term carry the
snapshot's last included index and term. The blob is opaque binary
(embedded NULs legal; snap_len is authoritative). An encoded
install_snapshot must fit raft_tcp.w's 1 MiB frame cap (rt_max_frame)
to ride that transport — nothing here enforces it; the transport
refuses oversize frames at send.

raft_wire_decode allocates the returned raft_msg (free with
raft_msg_free). Entry commands are opaque, length-carrying byte
buffers (raft_entry.command_len is authoritative, never strlen) —
raft_entry_new COPIES cmd_len bytes straight out of the decode buffer,
so decode reads the wire buffer directly with no intermediate
malloc'd copy and no leak: the entry's owned copy is freed like
everything else by raft_msg_free / raft_entry_free. Decoded snapshot
blobs work the same way they always did: the message OWNS its blob
(raft_msg_free frees it) and receivers copy it on install.

Node ids must be non-negative (asserted on encode); malformed input
makes decode return 0, never crash: every length is bounds-checked
against the buffer before use.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.u64
import libs.standard.distributed.raft


void raft_wire_u32(char* p, int v):
	p[0] = v
	p[1] = v >> 8
	p[2] = v >> 16
	p[3] = v >> 24


int raft_wire_read_u32(char* p):
	return (p[0] & 255) | ((p[1] & 255) << 8) | ((p[2] & 255) << 16) | ((p[3] & 255) << 24)


# Encoded size of m in bytes.
int raft_wire_size(raft_msg* m):
	int n = 1 + 4 + 4 + 8
	if (m.type == raft_msg_vote_req()):
		return n + 8 + 8 + 1
	if (m.type == raft_msg_vote_reply()):
		return n + 1 + 1
	if (m.type == raft_msg_append()):
		n = n + 8 + 8 + 8 + 4
		int i = 0
		while (i < m.entries.length):
			raft_entry* e = m.entries[i]
			n = n + 8 + 4 + e.command_len
			i = i + 1
		return n
	if (m.type == raft_msg_append_reply()):
		return n + 1 + 8
	if (m.type == raft_msg_install_snapshot()):
		return n + 8 + 8 + 8 + 4 + m.snap_len
	assert1(0)
	return 0


# Writes exactly raft_wire_size(m) bytes into buf.
void raft_wire_encode(raft_msg* m, char* buf):
	assert1(m.from >= 0 && m.to >= 0)
	buf[0] = m.type
	raft_wire_u32(buf + 1, m.from)
	raft_wire_u32(buf + 5, m.to)
	u64_save_le(buf + 9, m.term)
	int off = 17
	if (m.type == raft_msg_vote_req()):
		u64_save_le(buf + off, m.last_log_index)
		u64_save_le(buf + off + 8, m.last_log_term)
		buf[off + 16] = m.prevote
		return
	if (m.type == raft_msg_vote_reply()):
		buf[off] = m.vote_granted
		buf[off + 1] = m.prevote
		return
	if (m.type == raft_msg_append()):
		u64_save_le(buf + off, m.prev_log_index)
		u64_save_le(buf + off + 8, m.prev_log_term)
		u64_save_le(buf + off + 16, m.leader_commit)
		raft_wire_u32(buf + off + 24, m.entries.length)
		off = off + 28
		int i = 0
		while (i < m.entries.length):
			raft_entry* e = m.entries[i]
			int cmd_len = e.command_len
			u64_save_le(buf + off, e.term)
			raft_wire_u32(buf + off + 8, cmd_len)
			int j = 0
			while (j < cmd_len):
				buf[off + 12 + j] = e.command[j]
				j = j + 1
			off = off + 12 + cmd_len
			i = i + 1
		return
	if (m.type == raft_msg_append_reply()):
		buf[off] = m.success
		u64_save_le(buf + off + 1, m.match_index)
		return
	if (m.type == raft_msg_install_snapshot()):
		u64_save_le(buf + off, m.prev_log_index)
		u64_save_le(buf + off + 8, m.prev_log_term)
		u64_save_le(buf + off + 16, m.leader_commit)
		raft_wire_u32(buf + off + 24, m.snap_len)
		int sb = 0
		while (sb < m.snap_len):
			buf[off + 28 + sb] = m.snap_data[sb]
			sb = sb + 1
		return
	assert1(0)


# Decodes len bytes into a new raft_msg (caller frees with
# raft_msg_free). Returns 0 on any malformed input: unknown type,
# short buffer, negative or overrunning lengths, trailing bytes.
raft_msg* raft_wire_decode(char* buf, int len):
	if (len < 17):
		return 0
	int type = buf[0] & 255
	if (type != raft_msg_vote_req() && type != raft_msg_vote_reply() && type != raft_msg_append() && type != raft_msg_append_reply() && type != raft_msg_install_snapshot()):
		return 0
	int from = raft_wire_read_u32(buf + 1)
	int to = raft_wire_read_u32(buf + 5)
	if (from < 0 || to < 0):
		return 0
	u64* term = u64_new()
	u64_load_le(term, buf + 9)
	raft_msg* m = raft_msg_new(type, from, to, term)
	u64_free(term)
	int off = 17
	if (type == raft_msg_vote_req()):
		if (len != off + 17):
			raft_msg_free(m)
			return 0
		u64_load_le(m.last_log_index, buf + off)
		u64_load_le(m.last_log_term, buf + off + 8)
		m.prevote = buf[off + 16] & 255
		return m
	if (type == raft_msg_vote_reply()):
		if (len != off + 2):
			raft_msg_free(m)
			return 0
		m.vote_granted = buf[off] & 255
		m.prevote = buf[off + 1] & 255
		return m
	if (type == raft_msg_append_reply()):
		if (len != off + 9):
			raft_msg_free(m)
			return 0
		m.success = buf[off] & 255
		u64_load_le(m.match_index, buf + off + 1)
		return m
	if (type == raft_msg_install_snapshot()):
		if (len < off + 28):
			raft_msg_free(m)
			return 0
		u64_load_le(m.prev_log_index, buf + off)
		u64_load_le(m.prev_log_term, buf + off + 8)
		u64_load_le(m.leader_commit, buf + off + 16)
		int blen = raft_wire_read_u32(buf + off + 24)
		if (blen < 0 || blen != len - off - 28):
			raft_msg_free(m)
			return 0
		char* blob = malloc(blen + 1)
		int bi = 0
		while (bi < blen):
			blob[bi] = buf[off + 28 + bi]
			bi = bi + 1
		blob[blen] = 0
		m.snap_data = blob
		m.snap_len = blen
		return m
	# append
	if (len < off + 28):
		raft_msg_free(m)
		return 0
	u64_load_le(m.prev_log_index, buf + off)
	u64_load_le(m.prev_log_term, buf + off + 8)
	u64_load_le(m.leader_commit, buf + off + 16)
	int count = raft_wire_read_u32(buf + off + 24)
	if (count < 0):
		raft_msg_free(m)
		return 0
	off = off + 28
	u64* eterm = u64_new()
	int i = 0
	while (i < count):
		if (len - off < 12):
			u64_free(eterm)
			raft_msg_free(m)
			return 0
		u64_load_le(eterm, buf + off)
		int cmd_len = raft_wire_read_u32(buf + off + 8)
		if (cmd_len < 0 || cmd_len > len - off - 12):
			u64_free(eterm)
			raft_msg_free(m)
			return 0
		m.entries.push(raft_entry_new(eterm, buf + off + 12, cmd_len))
		off = off + 12 + cmd_len
		i = i + 1
	u64_free(eterm)
	if (off != len):
		raft_msg_free(m)
		return 0
	return m
