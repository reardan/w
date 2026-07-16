# wbuild: x64
import lib.testing
import libs.standard.distributed.raft_wal


/*
Unit tests for the raft <-> wal persistence adapter: shadow diffing,
record round-trips, truncation, torn-tail recovery, and the vote-none
sentinel. Single-node rafts keep every scenario deterministic — an
election window of [50, 100] ms means a tick at 100 always fires, and
a lone node wins its election on the spot with no messages.
*/


# Distinct log paths per target so the 32- and 64-bit test binaries
# can run concurrently under wbuild without clobbering each other.
char* rwal_path(char* name):
	char* prefix = strjoin(c"bin/rwal_t", itoa(__word_size__))
	char* mid = strjoin(prefix, c"_")
	char* path = strjoin(mid, name)
	free(mid)
	free(prefix)
	return path


int rwal_term_int(raft* r):
	u64* t = u64_new()
	raft_term(r, t)
	int v = u64_to_int(t)
	u64_free(t)
	return v


int rwal_commit_int(raft* r):
	u64* ci = u64_new()
	raft_commit_index(r, ci)
	int v = u64_to_int(ci)
	u64_free(ci)
	return v


int rwal_shadow_term_int(raft_wal* rw):
	u64* t = u64_new()
	raft_wal_shadow_term(rw, t)
	int v = u64_to_int(t)
	u64_free(t)
	return v


raft* rwal_single_node(int seed):
	list[int] peers = new list[int]
	return raft_new(1, peers, 50, 100, 10, seed)


# Hand-build a log entry (persistent fields are public by design; the
# truncation scenario constructs divergent logs directly).
void rwal_push_entry(raft* r, int term, char* command):
	u64* t = u64_new_int(term)
	r.log.push(raft_entry_new(t, command))
	u64_free(t)


# ---- clean sync -------------------------------------------------------------

void test_fresh_sync_clean():
	char* path = rwal_path(c"fresh.log")
	create_file(path, 420)   # start empty even on reruns
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	raft* r = rwal_single_node(42)
	assert_equal(0, raft_wal_pending(rw, r))
	assert_equal(0, raft_wal_sync(rw, r))
	assert_equal(0, raft_wal_shadow_log_length(rw))
	assert_equal(0, rwal_shadow_term_int(rw))
	assert_equal(0 - 1, raft_wal_shadow_voted_for(rw))
	raft_free(r)
	raft_wal_close(rw)
	free(path)


# ---- election persists term and vote ------------------------------------------

void test_election_state_record():
	char* path = rwal_path(c"state.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	raft* r = rwal_single_node(42)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)   # deadline passed: term 1, self-vote, leader
	assert_equal(0, out.length)
	assert_equal(raft_leader(), raft_state(r))
	assert_equal(1, raft_wal_pending(rw, r))
	assert_equal(1, raft_wal_sync(rw, r))   # one STATE record covers both
	# the sync fsynced internally (asserted in raft_wal_sync); the fd
	# is still healthy for an explicit follow-up flush
	assert_equal(1, wal_sync(rw.wlog))
	assert_equal(0, raft_wal_pending(rw, r))
	assert_equal(0, raft_wal_sync(rw, r))
	assert_equal(1, rwal_shadow_term_int(rw))
	assert_equal(1, raft_wal_shadow_voted_for(rw))
	assert_equal(0, raft_wal_shadow_log_length(rw))
	# recover into a fresh raft: term and vote survive, the log is empty
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw, 1, peers, 50, 100, 10, 43)
	assert_equal(raft_follower(), raft_state(r2))
	assert_equal(1, rwal_term_int(r2))
	assert_equal(1, raft_voted_for(r2))
	assert_equal(0, raft_log_length(r2))
	raft_free(r2)
	raft_free(r)
	raft_wal_close(rw)
	free(path)


# ---- proposals round-trip and recommit -----------------------------------------

void test_propose_recover_commit():
	char* path = rwal_path(c"prop.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	raft* r = rwal_single_node(42)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)
	assert_equal(1, raft_wal_sync(rw, r))   # STATE for the election
	assert_equal(1, raft_propose(r, c"a", 100, out))
	assert_equal(1, raft_propose(r, c"b", 101, out))
	assert_equal(1, raft_propose(r, c"c", 102, out))
	assert_equal(0, out.length)
	assert_equal(3, rwal_commit_int(r))
	assert_equal(3, raft_wal_sync(rw, r))   # three APPEND records
	raft_free(r)
	raft_wal_close(rw)
	# a crash later, the reopened adapter replays its shadow...
	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	assert_equal(3, raft_wal_shadow_log_length(rw2))
	assert_equal(1, rwal_shadow_term_int(rw2))
	assert_equal(1, raft_wal_shadow_voted_for(rw2))
	# ...and recovery rebuilds the raft: same term, vote, entries
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 50, 100, 10, 44)
	assert_equal(0, raft_wal_pending(rw2, r2))
	assert_equal(0, raft_wal_sync(rw2, r2))   # recovery is already persisted
	assert_equal(3, raft_log_length(r2))
	assert_equal(1, rwal_term_int(r2))
	assert_equal(1, raft_voted_for(r2))
	raft_entry* e1 = raft_log_at(r2, 1)
	assert_equal(1, u64_to_int(e1.term))
	assert_strings_equal(c"a", e1.command)
	raft_entry* e2 = raft_log_at(r2, 2)
	assert_equal(1, u64_to_int(e2.term))
	assert_strings_equal(c"b", e2.command)
	raft_entry* e3 = raft_log_at(r2, 3)
	assert_equal(1, u64_to_int(e3.term))
	assert_strings_equal(c"c", e3.command)
	# volatile state re-derived from zero: nothing is committed yet
	assert_equal(0, rwal_commit_int(r2))
	assert_equal(0, raft_pending_apply(r2))
	# the restarted node wins its single-node election again; per
	# section 5.4.2 the recovered term-1 entries commit once a
	# current-term entry lands, so pin one and drain the applies
	raft_start(r2, 200)
	raft_tick(r2, 300, out)
	assert_equal(raft_leader(), raft_state(r2))
	assert_equal(2, rwal_term_int(r2))
	assert_equal(1, raft_propose(r2, c"pin", 300, out))
	assert_equal(0, out.length)
	assert_equal(4, rwal_commit_int(r2))
	raft_entry* a1 = raft_pop_apply(r2)
	assert_strings_equal(c"a", a1.command)
	raft_entry* a2 = raft_pop_apply(r2)
	assert_strings_equal(c"b", a2.command)
	raft_entry* a3 = raft_pop_apply(r2)
	assert_strings_equal(c"c", a3.command)
	raft_entry* a4 = raft_pop_apply(r2)
	assert_strings_equal(c"pin", a4.command)
	assert_equal(0, raft_pending_apply(r2))
	# the re-election and the pin still need persisting
	assert_equal(2, raft_wal_sync(rw2, r2))   # STATE + APPEND(pin)
	assert_equal(0, raft_wal_pending(rw2, r2))
	raft_free(r2)
	raft_wal_close(rw2)
	free(path)


# ---- divergence emits TRUNCATE --------------------------------------------------

void test_truncation_divergence():
	char* path = rwal_path(c"trunc.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	# raft A: term 2, voted self, log terms [1, 1]
	raft* a = rwal_single_node(42)
	u64_set_int(a.current_term, 2)
	a.voted_for = 1
	rwal_push_entry(a, 1, c"x")
	rwal_push_entry(a, 1, c"y")
	assert_equal(3, raft_wal_sync(rw, a))   # STATE + two APPENDs
	assert_equal(3, wal_record_count(rw.wlog))
	# raft B shares entry 1 and the persistent term/vote, but its
	# index 2 came from a newer leader: terms [1, 2] — exactly the
	# shape raft_handle_append's conflict path produces
	raft* b = rwal_single_node(43)
	u64_set_int(b.current_term, 2)
	b.voted_for = 1
	rwal_push_entry(b, 1, c"x")
	rwal_push_entry(b, 2, c"z")
	assert_equal(1, raft_wal_pending(rw, b))
	assert_equal(2, raft_wal_sync(rw, b))   # TRUNCATE(1) + APPEND, no STATE
	assert_equal(5, wal_record_count(rw.wlog))
	assert_equal(2, raft_wal_shadow_log_length(rw))
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw, 1, peers, 50, 100, 10, 44)
	assert_equal(2, raft_log_length(r2))
	raft_entry* e1 = raft_log_at(r2, 1)
	assert_equal(1, u64_to_int(e1.term))
	assert_strings_equal(c"x", e1.command)
	raft_entry* e2 = raft_log_at(r2, 2)
	assert_equal(2, u64_to_int(e2.term))
	assert_strings_equal(c"z", e2.command)
	raft_free(r2)
	raft_free(b)
	raft_free(a)
	raft_wal_close(rw)
	free(path)


# ---- torn tail recovers the valid prefix ------------------------------------------

void test_torn_tail_prefix_state():
	char* path = rwal_path(c"torn.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	raft* r = rwal_single_node(42)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)
	assert_equal(1, raft_wal_sync(rw, r))   # STATE: term 1, vote 1
	assert_equal(1, raft_propose(r, c"a", 100, out))
	assert_equal(1, raft_wal_sync(rw, r))   # APPEND a
	assert_equal(1, raft_propose(r, c"bb", 101, out))
	assert_equal(1, raft_wal_sync(rw, r))   # APPEND bb
	int full = wal_size(rw.wlog)
	raft_free(r)
	raft_wal_close(rw)
	# tear the last record: rewrite the file cut 4 bytes short
	int fd = open(path, 0, 0)
	char* buf = malloc(full)
	assert_equal(full, read_exact(fd, buf, full))
	close(fd)
	fd = create_file(path, 420)
	assert_equal(full - 4, write_all(fd, buf, full - 4))
	close(fd)
	free(buf)
	# reopen: only the valid prefix survives — STATE + APPEND(a)
	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	assert_equal(2, wal_record_count(rw2.wlog))
	assert_equal(1, raft_wal_shadow_log_length(rw2))
	assert_equal(1, rwal_shadow_term_int(rw2))
	assert_equal(1, raft_wal_shadow_voted_for(rw2))
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 50, 100, 10, 45)
	assert_equal(1, raft_log_length(r2))
	assert_equal(1, rwal_term_int(r2))
	assert_equal(1, raft_voted_for(r2))
	raft_entry* e1 = raft_log_at(r2, 1)
	assert_equal(1, u64_to_int(e1.term))
	assert_strings_equal(c"a", e1.command)
	raft_free(r2)
	raft_wal_close(rw2)
	free(path)


# ---- the vote-none sentinel round-trips ------------------------------------------

void test_vote_none_roundtrip():
	char* path = rwal_path(c"vnone.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	# a term adopted from another node's higher-term message: term
	# moves, the vote stays none (raft_step_down's shape)
	raft* r = rwal_single_node(42)
	u64_set_int(r.current_term, 3)
	assert_equal(0 - 1, raft_voted_for(r))
	assert_equal(1, raft_wal_sync(rw, r))
	assert_equal(0 - 1, raft_wal_shadow_voted_for(rw))
	raft_free(r)
	raft_wal_close(rw)
	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	assert_equal(3, rwal_shadow_term_int(rw2))
	assert_equal(0 - 1, raft_wal_shadow_voted_for(rw2))
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 50, 100, 10, 46)
	assert_equal(3, rwal_term_int(r2))
	assert_equal(0 - 1, raft_voted_for(r2))
	assert_equal(0, raft_log_length(r2))
	raft_free(r2)
	raft_wal_close(rw2)
	free(path)


# ---- snapshot rewrite compacts the wal (§7) -----------------------------------------

int rwal_snap_index_int(raft* r):
	u64* v = u64_new()
	raft_snapshot_index(r, v)
	int n = u64_to_int(v)
	u64_free(v)
	return n


int rwal_snap_term_int(raft* r):
	u64* v = u64_new()
	raft_snapshot_term(r, v)
	int n = u64_to_int(v)
	u64_free(v)
	return n


void test_snapshot_rewrite_compacts_wal():
	char* path = rwal_path(c"snap.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	raft* r = rwal_single_node(42)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)
	assert_equal(1, raft_wal_sync(rw, r))   # STATE
	assert_equal(1, raft_propose(r, c"a", 100, out))
	assert_equal(1, raft_propose(r, c"b", 101, out))
	assert_equal(1, raft_propose(r, c"c", 102, out))
	assert_equal(1, raft_propose(r, c"d", 103, out))
	assert_equal(1, raft_propose(r, c"e", 104, out))
	assert_equal(5, raft_wal_sync(rw, r))   # five APPENDs
	assert_equal(6, wal_record_count(rw.wlog))
	int before = wal_size(rw.wlog)
	# apply three, snapshot at 3 with a binary blob (embedded zeros)
	raft_entry* a1 = raft_pop_apply(r)
	assert_strings_equal(c"a", a1.command)
	raft_entry* a2 = raft_pop_apply(r)
	assert_strings_equal(c"b", a2.command)
	raft_entry* a3 = raft_pop_apply(r)
	assert_strings_equal(c"c", a3.command)
	char* blob = malloc(5)
	blob[0] = 9
	blob[1] = 0
	blob[2] = 8
	blob[3] = 0
	blob[4] = 7
	assert_equal(1, raft_take_snapshot(r, blob, 5))
	assert_equal(1, raft_wal_pending(rw, r))
	# the sync REWRITES the wal: SNAPSHOT + STATE + APPEND(d) + APPEND(e)
	assert_equal(4, raft_wal_sync(rw, r))
	assert_equal(4, wal_record_count(rw.wlog))
	assert1(wal_size(rw.wlog) < before)
	assert_equal(0, raft_wal_pending(rw, r))
	assert_equal(0, raft_wal_sync(rw, r))
	assert_equal(2, raft_wal_shadow_log_length(rw))
	raft_free(r)
	raft_wal_close(rw)
	# crash + reopen: the snapshot survives into the recovered raft
	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	assert_equal(4, wal_record_count(rw2.wlog))
	assert_equal(2, raft_wal_shadow_log_length(rw2))
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 50, 100, 10, 44)
	assert_equal(0, raft_wal_pending(rw2, r2))
	assert_equal(0, raft_wal_sync(rw2, r2))
	assert_equal(3, rwal_snap_index_int(r2))
	assert_equal(1, rwal_snap_term_int(r2))
	assert_equal(2, raft_log_length(r2))
	assert_equal(5, raft_last_index(r2))
	# the snapshot's state is committed and applied by definition
	assert_equal(3, rwal_commit_int(r2))
	assert_equal(0, raft_pending_apply(r2))
	raft_entry* e4 = raft_log_at(r2, 4)
	assert_equal(1, u64_to_int(e4.term))
	assert_strings_equal(c"d", e4.command)
	raft_entry* e5 = raft_log_at(r2, 5)
	assert_strings_equal(c"e", e5.command)
	# the blob comes back through the pending slot, content-equal
	assert_equal(1, raft_has_pending_snapshot(r2))
	int blen = 0
	u64* bidx = u64_new()
	char* got = raft_take_pending_snapshot(r2, &blen, bidx)
	assert_equal(5, blen)
	assert_equal(9, got[0] & 255)
	assert_equal(0, got[1] & 255)
	assert_equal(8, got[2] & 255)
	assert_equal(0, got[3] & 255)
	assert_equal(7, got[4] & 255)
	assert_equal(3, u64_to_int(bidx))
	free(got)
	u64_free(bidx)
	# a sync after recovery appends only genuine changes: a fresh
	# election bumps the term, one STATE record follows
	raft_start(r2, 200)
	raft_tick(r2, 300, out)
	assert_equal(raft_leader(), raft_state(r2))
	assert_equal(2, rwal_term_int(r2))
	assert_equal(1, raft_wal_sync(rw2, r2))
	assert_equal(5, wal_record_count(rw2.wlog))
	assert_equal(0, raft_wal_pending(rw2, r2))
	free(blob)
	raft_free(r2)
	raft_wal_close(rw2)
	free(path)


# ---- torn tail after a snapshot record ------------------------------------------------

void test_snapshot_torn_tail():
	char* path = rwal_path(c"snaptorn.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	raft* r = rwal_single_node(42)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)
	assert_equal(1, raft_propose(r, c"a", 100, out))
	assert_equal(1, raft_propose(r, c"b", 101, out))
	assert_equal(3, raft_wal_sync(rw, r))   # STATE + APPEND a + APPEND b
	raft_entry* a1 = raft_pop_apply(r)
	assert_strings_equal(c"a", a1.command)
	raft_entry* a2 = raft_pop_apply(r)
	assert_strings_equal(c"b", a2.command)
	assert_equal(1, raft_take_snapshot(r, c"T2", 2))
	assert_equal(2, raft_wal_sync(rw, r))   # rewrite: SNAPSHOT + STATE
	assert_equal(1, raft_propose(r, c"c", 105, out))
	assert_equal(1, raft_propose(r, c"dd", 106, out))
	assert_equal(2, raft_wal_sync(rw, r))   # APPEND c + APPEND dd
	assert_equal(4, wal_record_count(rw.wlog))
	int full = wal_size(rw.wlog)
	raft_free(r)
	raft_wal_close(rw)
	# tear the final record: rewrite the file cut 4 bytes short
	int fd = open(path, 0, 0)
	char* buf = malloc(full)
	assert_equal(full, read_exact(fd, buf, full))
	close(fd)
	fd = create_file(path, 420)
	assert_equal(full - 4, write_all(fd, buf, full - 4))
	close(fd)
	free(buf)
	# reopen: SNAPSHOT + STATE + APPEND(c) survive, the torn APPEND(dd)
	# is discarded
	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	assert_equal(3, wal_record_count(rw2.wlog))
	assert_equal(1, raft_wal_shadow_log_length(rw2))
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 50, 100, 10, 45)
	assert_equal(2, rwal_snap_index_int(r2))
	assert_equal(1, rwal_snap_term_int(r2))
	assert_equal(1, raft_log_length(r2))
	assert_equal(3, raft_last_index(r2))
	assert_equal(2, rwal_commit_int(r2))
	assert_equal(1, rwal_term_int(r2))
	raft_entry* e3 = raft_log_at(r2, 3)
	assert_strings_equal(c"c", e3.command)
	# pending blob intact through the torn tail
	assert_equal(1, raft_has_pending_snapshot(r2))
	int blen = 0
	u64* bidx = u64_new()
	char* got = raft_take_pending_snapshot(r2, &blen, bidx)
	assert_equal(2, blen)
	assert_equal('T', got[0] & 255)
	assert_equal('2', got[1] & 255)
	assert_equal(2, u64_to_int(bidx))
	free(got)
	u64_free(bidx)
	raft_free(r2)
	raft_wal_close(rw2)
	free(path)
