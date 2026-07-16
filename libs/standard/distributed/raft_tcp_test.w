# wbuild: x64
# Loopback tests for the raft TCP transport: real sockets in one
# process, driven purely by bounded raft_tcp_pump loops (no sleeps —
# loopback progress is deterministic, the iteration caps are just a
# safety net).
#
# Ports: 21000 + __word_size__ * 100 + per-test offset, so the 32- and
# 64-bit test binaries use disjoint ranges (21400 vs 21800) and can run
# concurrently. Collisions with unrelated processes are theoretically
# possible but the range is quiet.
import lib.testing
import libs.standard.distributed.raft_tcp


int rt_port_base():
	return 21000 + __word_size__ * 100


raft_msg* rt_make_msg(int type, int from, int to, int term_v):
	u64* term = u64_new_int(term_v)
	raft_msg* m = raft_msg_new(type, from, to, term)
	u64_free(term)
	return m


# Pumps every given endpoint until the summed inbox count reaches
# want_total_inbox, asserting if max_iters passes run out first.
void rt_pump_until(raft_tcp* a, raft_tcp* b, raft_tcp* c_or_0, int want_total_inbox, int max_iters):
	int i = 0
	while (i < max_iters):
		raft_tcp_pump(a)
		raft_tcp_pump(b)
		if (cast(int, c_or_0) != 0):
			raft_tcp_pump(c_or_0)
		int total = raft_tcp_inbox_count(a) + raft_tcp_inbox_count(b)
		if (cast(int, c_or_0) != 0):
			total = total + raft_tcp_inbox_count(c_or_0)
		if (total >= want_total_inbox):
			return
		i = i + 1
	asserts(c"rt_pump_until: inbox target not reached", 0)


void test_vote_req_and_reply():
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base)
	assert1(cast(int, a) != 0)
	raft_tcp* b = raft_tcp_new(2, base + 1)
	assert1(cast(int, b) != 0)
	raft_tcp_add_peer(a, 2, base + 1)
	raft_tcp_add_peer(b, 1, base)

	raft_msg* m = rt_make_msg(raft_msg_vote_req(), 1, 2, 7)
	u64_set_int(m.last_log_index, 42)
	u64_set_int(m.last_log_term, 6)
	assert_equal(1, raft_tcp_send(a, m))
	raft_msg_free(m)

	rt_pump_until(a, b, 0, 1, 100000)
	assert_equal(1, raft_tcp_inbox_count(b))
	raft_msg* got = raft_tcp_recv(b)
	assert1(cast(int, got) != 0)
	assert_equal(raft_msg_vote_req(), got.type)
	assert_equal(1, got.from)
	assert_equal(2, got.to)
	assert_equal(7, raft_u64_as_int(got.term))
	assert_equal(42, raft_u64_as_int(got.last_log_index))
	assert_equal(6, raft_u64_as_int(got.last_log_term))
	raft_msg_free(got)

	raft_msg* reply = rt_make_msg(raft_msg_vote_reply(), 2, 1, 7)
	reply.vote_granted = 1
	assert_equal(1, raft_tcp_send(b, reply))
	raft_msg_free(reply)

	rt_pump_until(a, b, 0, 1, 100000)
	raft_msg* got2 = raft_tcp_recv(a)
	assert1(cast(int, got2) != 0)
	assert_equal(raft_msg_vote_reply(), got2.type)
	assert_equal(2, got2.from)
	assert_equal(1, got2.to)
	assert_equal(1, got2.vote_granted)
	raft_msg_free(got2)

	assert_equal(0, cast(int, raft_tcp_recv(a)))
	raft_tcp_free(a)
	raft_tcp_free(b)


void test_append_entries_and_heartbeat():
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base + 2)
	raft_tcp* b = raft_tcp_new(2, base + 3)
	assert1(cast(int, a) != 0 && cast(int, b) != 0)
	raft_tcp_add_peer(a, 2, base + 3)

	raft_msg* m = rt_make_msg(raft_msg_append(), 1, 2, 9)
	u64_set_int(m.prev_log_index, 10)
	u64_set_int(m.prev_log_term, 8)
	u64_set_int(m.leader_commit, 10)
	u64* t1 = u64_new_int(8)
	u64* t2 = u64_new_int(9)
	m.entries.push(raft_entry_new(t1, c"P\tk1\tv1", 7))
	m.entries.push(raft_entry_new(t2, c"D\tk2", 4))
	assert_equal(1, raft_tcp_send(a, m))
	raft_msg_free(m)
	u64_free(t1)
	u64_free(t2)

	rt_pump_until(a, b, 0, 1, 100000)
	raft_msg* got = raft_tcp_recv(b)
	assert1(cast(int, got) != 0)
	assert_equal(raft_msg_append(), got.type)
	assert_equal(2, got.entries.length)
	raft_entry* e0 = got.entries[0]
	raft_entry* e1 = got.entries[1]
	assert_equal(8, raft_u64_as_int(e0.term))
	assert_strings_equal(c"P\tk1\tv1", e0.command)
	assert_equal(9, raft_u64_as_int(e1.term))
	assert_strings_equal(c"D\tk2", e1.command)
	assert_equal(10, raft_u64_as_int(got.prev_log_index))
	assert_equal(8, raft_u64_as_int(got.prev_log_term))
	assert_equal(10, raft_u64_as_int(got.leader_commit))
	raft_msg_free(got)

	# Heartbeat: empty entries list still arrives as an append.
	raft_msg* hb = rt_make_msg(raft_msg_append(), 1, 2, 9)
	assert_equal(1, raft_tcp_send(a, hb))
	raft_msg_free(hb)
	rt_pump_until(a, b, 0, 1, 100000)
	raft_msg* got2 = raft_tcp_recv(b)
	assert1(cast(int, got2) != 0)
	assert_equal(raft_msg_append(), got2.type)
	assert_equal(0, got2.entries.length)
	raft_msg_free(got2)

	raft_tcp_free(a)
	raft_tcp_free(b)


void test_fifty_appends_arrive_in_order():
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base + 4)
	raft_tcp* b = raft_tcp_new(2, base + 5)
	assert1(cast(int, a) != 0 && cast(int, b) != 0)
	raft_tcp_add_peer(a, 2, base + 5)

	# Queue all 50 before any pump: the receiver's accumulator must
	# split the coalesced byte stream back into frames.
	int i = 0
	while (i < 50):
		raft_msg* m = rt_make_msg(raft_msg_append(), 1, 2, i + 1)
		assert_equal(1, raft_tcp_send(a, m))
		raft_msg_free(m)
		i = i + 1

	rt_pump_until(a, b, 0, 50, 100000)
	assert_equal(50, raft_tcp_inbox_count(b))
	i = 0
	while (i < 50):
		raft_msg* got = raft_tcp_recv(b)
		assert1(cast(int, got) != 0)
		assert_equal(raft_msg_append(), got.type)
		assert_equal(i + 1, raft_u64_as_int(got.term))
		raft_msg_free(got)
		i = i + 1

	raft_tcp_free(a)
	raft_tcp_free(b)


void test_interleaved_bidirectional():
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base + 6)
	raft_tcp* b = raft_tcp_new(2, base + 7)
	assert1(cast(int, a) != 0 && cast(int, b) != 0)
	raft_tcp_add_peer(a, 2, base + 7)
	raft_tcp_add_peer(b, 1, base + 6)

	int i = 0
	while (i < 20):
		raft_msg* ma = rt_make_msg(raft_msg_append(), 1, 2, i + 1)
		assert_equal(1, raft_tcp_send(a, ma))
		raft_msg_free(ma)
		raft_msg* mb = rt_make_msg(raft_msg_append_reply(), 2, 1, 101 + i)
		u64_set_int(mb.match_index, i + 1)
		assert_equal(1, raft_tcp_send(b, mb))
		raft_msg_free(mb)
		i = i + 1

	rt_pump_until(a, b, 0, 40, 100000)
	assert_equal(20, raft_tcp_inbox_count(a))
	assert_equal(20, raft_tcp_inbox_count(b))
	i = 0
	while (i < 20):
		raft_msg* got_b = raft_tcp_recv(b)
		assert_equal(1, got_b.from)
		assert_equal(i + 1, raft_u64_as_int(got_b.term))
		raft_msg_free(got_b)
		raft_msg* got_a = raft_tcp_recv(a)
		assert_equal(2, got_a.from)
		assert_equal(101 + i, raft_u64_as_int(got_a.term))
		assert_equal(i + 1, raft_u64_as_int(got_a.match_index))
		raft_msg_free(got_a)
		i = i + 1

	raft_tcp_free(a)
	raft_tcp_free(b)


void test_three_node_ring():
	int base = rt_port_base()
	raft_tcp* n1 = raft_tcp_new(1, base + 8)
	raft_tcp* n2 = raft_tcp_new(2, base + 9)
	raft_tcp* n3 = raft_tcp_new(3, base + 10)
	assert1(cast(int, n1) != 0 && cast(int, n2) != 0 && cast(int, n3) != 0)
	raft_tcp_add_peer(n1, 2, base + 9)
	raft_tcp_add_peer(n2, 3, base + 10)
	raft_tcp_add_peer(n3, 1, base + 8)

	raft_msg* m12 = rt_make_msg(raft_msg_vote_reply(), 1, 2, 11)
	raft_msg* m23 = rt_make_msg(raft_msg_vote_reply(), 2, 3, 22)
	raft_msg* m31 = rt_make_msg(raft_msg_vote_reply(), 3, 1, 33)
	assert_equal(1, raft_tcp_send(n1, m12))
	assert_equal(1, raft_tcp_send(n2, m23))
	assert_equal(1, raft_tcp_send(n3, m31))
	raft_msg_free(m12)
	raft_msg_free(m23)
	raft_msg_free(m31)

	rt_pump_until(n1, n2, n3, 3, 100000)
	assert_equal(1, raft_tcp_inbox_count(n1))
	assert_equal(1, raft_tcp_inbox_count(n2))
	assert_equal(1, raft_tcp_inbox_count(n3))

	raft_msg* got1 = raft_tcp_recv(n1)
	assert_equal(3, got1.from)
	assert_equal(1, got1.to)
	assert_equal(33, raft_u64_as_int(got1.term))
	raft_msg_free(got1)
	raft_msg* got2 = raft_tcp_recv(n2)
	assert_equal(1, got2.from)
	assert_equal(2, got2.to)
	assert_equal(11, raft_u64_as_int(got2.term))
	raft_msg_free(got2)
	raft_msg* got3 = raft_tcp_recv(n3)
	assert_equal(2, got3.from)
	assert_equal(3, got3.to)
	assert_equal(22, raft_u64_as_int(got3.term))
	raft_msg_free(got3)

	raft_tcp_free(n1)
	raft_tcp_free(n2)
	raft_tcp_free(n3)


void test_unknown_peer_send_fails():
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base + 11)
	assert1(cast(int, a) != 0)
	raft_msg* m = rt_make_msg(raft_msg_vote_req(), 1, 99, 1)
	assert_equal(0, raft_tcp_send(a, m))
	raft_msg_free(m)
	raft_tcp_free(a)


void test_send_before_peer_listens():
	# The transport keeps a peer's outbound buffer across connection
	# failures and re-dials on every pump while bytes are pending, so
	# a frame sent before the peer starts listening is delivered once
	# the peer appears (see raft_tcp.w header).
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base + 12)
	assert1(cast(int, a) != 0)
	raft_tcp_add_peer(a, 2, base + 13)

	raft_msg* m = rt_make_msg(raft_msg_vote_req(), 1, 2, 5)
	u64_set_int(m.last_log_index, 3)
	assert_equal(1, raft_tcp_send(a, m))
	raft_msg_free(m)

	# Nothing listens yet: pumps observe the refused connect, drop the
	# socket, and retain the buffered frame.
	int i = 0
	while (i < 20):
		raft_tcp_pump(a)
		i = i + 1
	assert_equal(0, raft_tcp_inbox_count(a))

	raft_tcp* b = raft_tcp_new(2, base + 13)
	assert1(cast(int, b) != 0)
	rt_pump_until(a, b, 0, 1, 100000)
	raft_msg* got = raft_tcp_recv(b)
	assert1(cast(int, got) != 0)
	assert_equal(raft_msg_vote_req(), got.type)
	assert_equal(1, got.from)
	assert_equal(2, got.to)
	assert_equal(5, raft_u64_as_int(got.term))
	assert_equal(3, raft_u64_as_int(got.last_log_index))
	raft_msg_free(got)

	# Steady state after the late join: a second send arrives too.
	raft_msg* m2 = rt_make_msg(raft_msg_append(), 1, 2, 6)
	assert_equal(1, raft_tcp_send(a, m2))
	raft_msg_free(m2)
	rt_pump_until(a, b, 0, 1, 100000)
	raft_msg* got2 = raft_tcp_recv(b)
	assert_equal(raft_msg_append(), got2.type)
	assert_equal(6, raft_u64_as_int(got2.term))
	raft_msg_free(got2)

	raft_tcp_free(a)
	raft_tcp_free(b)


void test_cap_bounds_dead_peer_buffer():
	# Peer 2 is registered but never created, so every send only
	# buffers and no byte ever reaches a socket: cap enforcement is
	# exactly countable. Heartbeat-sized appends must never push the
	# buffer past the cap, and the drop counter must match the
	# arithmetic (fit frames kept, the rest dropped oldest-first).
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base + 14)
	assert1(cast(int, a) != 0)
	raft_tcp_add_peer(a, 2, base + 15)
	raft_tcp_set_max_pending(a, 8192)

	raft_msg* probe = rt_make_msg(raft_msg_append(), 1, 2, 1)
	int fsize = raft_wire_size(probe) + 4
	raft_msg_free(probe)
	int fit = 8192 / fsize
	assert1(fit > 0 && fit < 200)

	int i = 0
	while (i < 200):
		raft_msg* m = rt_make_msg(raft_msg_append(), 1, 2, i + 1)
		assert_equal(1, raft_tcp_send(a, m))
		raft_msg_free(m)
		asserts(c"pending never exceeds the cap", raft_tcp_pending_bytes(a, 2) <= 8192)
		i = i + 1

	assert_equal(fit * fsize, raft_tcp_pending_bytes(a, 2))
	assert_equal(fit, raft_tcp_pending_frames(a, 2))
	assert_equal(200 - fit, raft_tcp_dropped_frames(a))
	raft_tcp_free(a)


void test_cap_keeps_freshest_frames():
	# Fill a dead peer's buffer far past the cap with distinguishable
	# frames, then bring the peer up: exactly the newest `fit` frames
	# must arrive, in order and intact. Nothing was ever written to a
	# socket before B appeared, so every drop removed a whole frame
	# and the stream cannot desync.
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base + 16)
	assert1(cast(int, a) != 0)
	raft_tcp_add_peer(a, 2, base + 17)
	raft_tcp_set_max_pending(a, 4096)

	raft_msg* probe = rt_make_msg(raft_msg_append_reply(), 1, 2, 3)
	int fsize = raft_wire_size(probe) + 4
	raft_msg_free(probe)
	int fit = 4096 / fsize
	int total = 200
	assert1(fit > 0 && fit < total)

	int i = 0
	while (i < total):
		raft_msg* m = rt_make_msg(raft_msg_append_reply(), 1, 2, 3)
		m.success = 1
		u64_set_int(m.match_index, i + 1)
		assert_equal(1, raft_tcp_send(a, m))
		raft_msg_free(m)
		i = i + 1
	assert_equal(total - fit, raft_tcp_dropped_frames(a))
	assert_equal(fit, raft_tcp_pending_frames(a, 2))

	raft_tcp* b = raft_tcp_new(2, base + 17)
	assert1(cast(int, b) != 0)
	rt_pump_until(a, b, 0, fit, 100000)
	assert_equal(fit, raft_tcp_inbox_count(b))
	assert_equal(0, raft_tcp_pending_bytes(a, 2))
	assert_equal(0, raft_tcp_pending_frames(a, 2))
	i = 0
	while (i < fit):
		raft_msg* got = raft_tcp_recv(b)
		assert1(cast(int, got) != 0)
		assert_equal(raft_msg_append_reply(), got.type)
		assert_equal(1, got.from)
		assert_equal(2, got.to)
		assert_equal(3, raft_u64_as_int(got.term))
		assert_equal(1, got.success)
		assert_equal(total - fit + i + 1, raft_u64_as_int(got.match_index))
		raft_msg_free(got)
		i = i + 1
	raft_tcp_free(a)
	raft_tcp_free(b)


void test_partial_head_accounting_with_slow_peer():
	# The never-drop-a-partially-sent-head rule is hard to force
	# deterministically on loopback: a mid-frame short write needs the
	# kernel socket buffers to fill at a non-frame boundary, and the
	# transport exposes no SO_SNDBUF knob to shrink them. So this test
	# asserts the invariant structurally instead: B exists but never
	# pumps during the exchange, A sends bursts and pumps, and after
	# every pump the accounting must satisfy
	#   pending_frames * fsize - pending_bytes == head_sent
	# with 0 <= head_sent < fsize — i.e. the head frame is either
	# fully intact in the buffer or split exactly at its already-sent
	# prefix. If a partial head were ever dropped, either this
	# equation breaks or the drained stream below decodes wrong.
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base + 18)
	raft_tcp* b = raft_tcp_new(2, base + 19)
	assert1(cast(int, a) != 0 && cast(int, b) != 0)
	raft_tcp_add_peer(a, 2, base + 19)
	raft_tcp_set_max_pending(a, 4096)

	raft_msg* probe = rt_make_msg(raft_msg_append(), 1, 2, 1)
	int fsize = raft_wire_size(probe) + 4
	raft_msg_free(probe)
	int fit = 4096 / fsize

	# Phase 1: burst with no pump at all — nothing is flushed, so the
	# cap engages exactly as in the dead-peer case and guarantees the
	# drop path ran before the exchange starts.
	int total = 3000
	int sent = 0
	while (sent < 150):
		raft_msg* m = rt_make_msg(raft_msg_append(), 1, 2, sent + 1)
		assert_equal(1, raft_tcp_send(a, m))
		raft_msg_free(m)
		sent = sent + 1
	assert_equal(150 - fit, raft_tcp_dropped_frames(a))

	# Phase 2: keep sending in bursts while only A pumps. B's kernel
	# buffers slowly fill, so short writes (a partially-sent head) and
	# cap drops around one can occur; the invariant is checked either
	# way after every pump.
	while (sent < total):
		int burst = 0
		while (burst < 5 && sent < total):
			raft_msg* m2 = rt_make_msg(raft_msg_append(), 1, 2, sent + 1)
			assert_equal(1, raft_tcp_send(a, m2))
			raft_msg_free(m2)
			sent = sent + 1
			burst = burst + 1
		raft_tcp_pump(a)
		int pb = raft_tcp_pending_bytes(a, 2)
		int pf = raft_tcp_pending_frames(a, 2)
		asserts(c"pending bytes stay bounded by the cap", pb >= 0 && pb <= 4096)
		int head_sent = pf * fsize - pb
		asserts(c"head frame intact or split at its sent prefix", head_sent >= 0 && head_sent < fsize)
		if (pf == 0):
			assert_equal(0, pb)

	# Drain: every surviving frame arrives intact and in order (terms
	# strictly increasing up to the very last send), proving the byte
	# stream never desynced.
	int expect = total - raft_tcp_dropped_frames(a)
	rt_pump_until(a, b, 0, expect, 200000)
	assert_equal(expect, raft_tcp_inbox_count(b))
	assert_equal(0, raft_tcp_pending_bytes(a, 2))
	assert_equal(0, raft_tcp_pending_frames(a, 2))
	int last = 0
	int k = 0
	while (k < expect):
		raft_msg* got = raft_tcp_recv(b)
		assert1(cast(int, got) != 0)
		assert_equal(raft_msg_append(), got.type)
		assert_equal(1, got.from)
		assert_equal(2, got.to)
		int term_v = raft_u64_as_int(got.term)
		asserts(c"terms strictly increasing", term_v > last)
		last = term_v
		raft_msg_free(got)
		k = k + 1
	asserts(c"newest frame survived", last == total)
	raft_tcp_free(a)
	raft_tcp_free(b)


void test_frame_over_cap_refused():
	# A frame bigger than the cap (but under rt_max_frame()) is
	# refused at send exactly like an oversize frame: return 0,
	# nothing buffered, no drops charged, existing frames untouched.
	int base = rt_port_base()
	raft_tcp* a = raft_tcp_new(1, base + 14)
	assert1(cast(int, a) != 0)
	raft_tcp_add_peer(a, 2, base + 15)
	raft_tcp_set_max_pending(a, 4096)

	char* cmd = malloc(5001)
	int i = 0
	while (i < 5000):
		cmd[i] = 120
		i = i + 1
	cmd[5000] = 0
	raft_msg* big = rt_make_msg(raft_msg_append(), 1, 2, 2)
	u64* et = u64_new_int(2)
	big.entries.push(raft_entry_new(et, cmd, 5000))
	u64_free(et)
	assert1(raft_wire_size(big) + 4 > 4096)
	assert1(raft_wire_size(big) <= rt_max_frame())

	# Empty buffer: refused, nothing buffered.
	assert_equal(0, raft_tcp_send(a, big))
	assert_equal(0, raft_tcp_pending_bytes(a, 2))
	assert_equal(0, raft_tcp_pending_frames(a, 2))
	assert_equal(0, raft_tcp_dropped_frames(a))

	# With a small frame queued: still refused, the queued frame and
	# the drop counter are untouched.
	raft_msg* small = rt_make_msg(raft_msg_append(), 1, 2, 1)
	assert_equal(1, raft_tcp_send(a, small))
	raft_msg_free(small)
	int pending_before = raft_tcp_pending_bytes(a, 2)
	assert_equal(0, raft_tcp_send(a, big))
	assert_equal(pending_before, raft_tcp_pending_bytes(a, 2))
	assert_equal(1, raft_tcp_pending_frames(a, 2))
	assert_equal(0, raft_tcp_dropped_frames(a))

	raft_msg_free(big)
	free(cmd)
	raft_tcp_free(a)
