# wbuild: x64
import lib.testing
import libs.standard.distributed.raft_wal


/*
Cluster membership persistence (issue #319; raft.w's "Cluster
membership changes" header) — a crash must not lose (or wrongly keep)
config-change effects. Config entries ride the ordinary WAL APPEND/
TRUNCATE records via raft_wal.w's replay hooks (raft_note_entry_
appended / raft_note_truncated_to, the SAME ones live raft_propose_
internal / raft_handle_append use), so current config recovers exactly
like term/vote/log; a SNAPSHOT record now also carries the FULL config
in effect at the snapshot boundary (raft_adopt_snapshot_config), so a
node whose log has been compacted still recovers the right config.

Single-node clusters (peers = [] at raft_new) commit a config
proposal immediately — self-only majority — keeping these scenarios
deterministic with no simulated network needed, matching raft_wal_
test.w's own style. The rollback scenario instead hand-builds two
divergent single-node "histories" sharing one wal file, mirroring
raft_wal_test.w's test_truncation_divergence exactly, to drive
raft_wal.w's TRUNCATE-tag replay path specifically (distinct from the
live raft_handle_append conflict path the sim tests already cover).
*/


# Distinct log paths per target so 32-/64-bit runs never collide.
char* rmr_path(char* name):
	char* prefix = strjoin(c"bin/rmr_t", itoa(__word_size__))
	char* mid = strjoin(prefix, c"_")
	char* path = strjoin(mid, name)
	free(mid)
	free(prefix)
	return path


raft* rmr_single_node(int seed):
	list[int] peers = new list[int]
	return raft_new(1, peers, 50, 100, 10, seed)


int rmr_has_peer(raft* r, int id):
	int i = 0
	while (i < raft_peer_count(r)):
		if (raft_peer_at(r, i) == id):
			return 1
		i = i + 1
	return 0


# Hand-build a config-change entry directly on r's log (persistent
# fields are public by design — raft_wal_test.w's rwal_push_entry
# precedent) and drive it through the SAME apply-on-append hook live
# operation uses, so r.peers/config_pending_index end up exactly as
# they would from a real raft_propose_add_server/remove_server call.
void rmr_push_config_entry(raft* r, int term, int op, int id):
	u64* t = u64_new_int(term)
	char* cmd = raft_config_encode(op, id)
	raft_entry* e = raft_entry_new_kind(t, cmd, 5, raft_entry_kind_config())
	r.log.push(e)
	raft_note_entry_appended(r, raft_last_index(r), e)
	free(cmd)
	u64_free(t)


void rmr_push_entry(raft* r, int term, char* command):
	u64* t = u64_new_int(term)
	r.log.push(raft_entry_new(t, command, strlen(command)))
	u64_free(t)


# ---- config survives an ordinary WAL replay ----------------------------------------

void test_config_survives_wal_replay():
	char* path = rmr_path(c"cfgwal.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	raft* r = rmr_single_node(1)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)   # single-node cluster: elects on the spot
	assert_equal(raft_leader(), raft_state(r))
	assert_equal(1, raft_wal_sync(rw, r))   # STATE
	# add 5, add 6, then remove 5. Hand-built directly (rmr_push_config_
	# entry — same precedent as raft_wal_test.w's rwal_push_entry)
	# rather than through raft_propose_add_server/remove_server: adding
	# a server to a single-node (self-only-majority) cluster changes the
	# majority requirement for its OWN entry the instant it is applied
	# (thesis §4.1's apply-on-append), so it can never self-commit
	# without a real second voter acking — and the single-in-flight rule
	# would then block every subsequent proposal forever. This test's
	# target is the WAL persistence contract (raft_note_entry_appended
	# replays identically to how it applies live), not end-to-end
	# commit dynamics, which the sim tests already cover with real
	# multi-node quorums.
	u64* t = u64_new()
	raft_term(r, t)
	int term = raft_u64_as_int(t)
	u64_free(t)
	rmr_push_config_entry(r, term, raft_config_op_add(), 5)
	rmr_push_config_entry(r, term, raft_config_op_add(), 6)
	rmr_push_config_entry(r, term, raft_config_op_remove(), 5)
	assert_equal(1, raft_peer_count(r))
	assert_equal(1, rmr_has_peer(r, 6))
	assert_equal(0, rmr_has_peer(r, 5))
	assert_equal(3, raft_wal_sync(rw, r))   # three APPEND records (config entries)
	raft_free(r)
	raft_wal_close(rw)

	# crash + reopen: current_term/voted_for/log come back through the
	# usual shadow replay, and the config comes back through the SAME
	# APPEND records via raft_note_entry_appended (raft_wal.w header)
	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 50, 100, 10, 2)
	assert_equal(3, raft_log_length(r2))
	# the last of the three (remove 5) never committed (commit_index
	# stayed volatile-zero — see above), so it is still the pending
	# in-flight change, exactly as it was before the crash
	assert_equal(1, raft_config_pending(r2))
	assert_equal(1, raft_peer_count(r2))
	assert_equal(1, rmr_has_peer(r2, 6))
	assert_equal(0, rmr_has_peer(r2, 5))
	assert_equal(0, raft_wal_sync(rw2, r2))   # recovery is already persisted
	raft_free(r2)
	raft_wal_close(rw2)
	free(path)


# ---- config-at-snapshot survives a snapshot + restart -------------------------------

void test_config_survives_snapshot_and_restart():
	char* path = rmr_path(c"cfgsnap.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	raft* r = rmr_single_node(10)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)
	assert_equal(raft_leader(), raft_state(r))
	assert_equal(1, raft_wal_sync(rw, r))   # STATE
	# hand-build (rmr_push_config_entry, header note) rather than
	# raft_propose_add_server: adding server 7 already raises the
	# majority to 2 (thesis §4.1 apply-on-append), so a real second
	# proposal would be rejected by the single-in-flight rule before
	# ever committing the first with no second voter around to ack it.
	# raft_take_snapshot below needs entries that are actually applied
	# (last_applied advances only past commit_index), so commit_index
	# is advanced by hand too, immediately followed by raft_note_
	# commit_advanced — precisely what raft_try_advance_commit/raft_
	# handle_append would have called had a real quorum ack driven it.
	u64* t = u64_new()
	raft_term(r, t)
	int term = raft_u64_as_int(t)
	u64_free(t)
	rmr_push_config_entry(r, term, raft_config_op_add(), 7)
	rmr_push_config_entry(r, term, raft_config_op_add(), 8)
	assert_equal(2, raft_peer_count(r))
	assert_equal(1, raft_config_pending(r))
	u64_set_int(r.commit_index, 2)
	raft_note_commit_advanced(r)
	assert_equal(0, raft_config_pending(r))
	# apply both
	raft_entry* a1 = raft_pop_apply(r)
	raft_entry* a2 = raft_pop_apply(r)
	assert_equal(0, raft_pending_apply(r))
	assert_equal(1, raft_take_snapshot(r, c"BLOB", 4))
	assert_equal(0, raft_log_length(r))
	# taking the snapshot does not itself change the LIVE config — only
	# what gets recorded in its own meta (raft_full_config_at_last_
	# applied); with nothing pending here the two are identical anyway
	assert_equal(2, raft_peer_count(r))
	assert_equal(2, raft_wal_sync(rw, r))   # rewrite: SNAPSHOT + STATE
	raft_free(r)
	raft_wal_close(rw)

	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 50, 100, 10, 11)
	# the snapshot's recorded config is adopted into r.peers immediately
	# on replay (raft_adopt_snapshot_config), independent of the
	# pending-blob handoff the state machine still needs to perform
	assert_equal(2, raft_peer_count(r2))
	assert_equal(1, rmr_has_peer(r2, 7))
	assert_equal(1, rmr_has_peer(r2, 8))
	assert_equal(0, raft_config_pending(r2))
	assert_equal(1, raft_has_pending_snapshot(r2))
	int blen = 0
	u64* bidx = u64_new()
	char* blob = raft_take_pending_snapshot(r2, &blen, bidx)
	assert_equal(4, blen)
	assert_equal('B', blob[0] & 255)
	free(blob)
	u64_free(bidx)
	assert_equal(0, raft_wal_sync(rw2, r2))
	raft_free(r2)
	raft_wal_close(rw2)
	free(path)


# ---- uncommitted-config rollback survives a WAL TRUNCATE replay --------------------

# Mirrors raft_wal_test.w's test_truncation_divergence exactly (two
# hand-built single-node "histories" sharing one wal file), but drives
# raft_wal.w's TRUNCATE-tag replay path specifically — distinct from
# (and a stronger persistence proof than) the live raft_handle_append
# conflict path the sim tests already cover: the rollback must
# reconstruct correctly from cold, not just react correctly live.
void test_config_rollback_survives_wal_truncate_replay():
	char* path = rmr_path(c"cfgtrunc.log")
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	# raft A: term 2, an uncommitted config add(9) at index 1 (term 1)
	raft* a = rmr_single_node(42)
	u64_set_int(a.current_term, 2)
	a.voted_for = 1
	rmr_push_config_entry(a, 1, raft_config_op_add(), 9)
	assert_equal(1, raft_config_pending(a))
	assert_equal(1, raft_peer_count(a))
	assert_equal(1, rmr_has_peer(a, 9))
	assert_equal(2, raft_wal_sync(rw, a))   # STATE + APPEND(config)
	assert_equal(2, wal_record_count(rw.wlog))

	# raft B shares the persistent term/vote but its index 1 came from
	# a newer leader: a normal "z" entry at term 2 — exactly the shape
	# raft_handle_append's conflict path produces
	raft* b = rmr_single_node(43)
	u64_set_int(b.current_term, 2)
	b.voted_for = 1
	rmr_push_entry(b, 2, c"z")
	assert_equal(1, raft_wal_pending(rw, b))
	assert_equal(2, raft_wal_sync(rw, b))   # TRUNCATE(0) + APPEND, no STATE
	assert_equal(4, wal_record_count(rw.wlog))
	raft_free(b)
	raft_free(a)
	raft_wal_close(rw)

	# recover: the wal's record sequence — STATE, APPEND(config),
	# TRUNCATE(0), APPEND(normal) — replays through the SAME hooks live
	# operation uses (raft_wal.w header), so the config-add's effect
	# must roll back exactly as it would have live: back to an empty
	# config, nothing pending, only the surviving normal entry
	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	list[int] peers = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers, 50, 100, 10, 44)
	assert_equal(1, raft_log_length(r2))
	raft_entry* e1 = raft_log_at(r2, 1)
	assert_equal(2, u64_to_int(e1.term))
	assert_strings_equal(c"z", e1.command)
	assert_equal(raft_entry_kind_normal(), e1.kind)
	assert_equal(0, raft_config_pending(r2))
	assert_equal(0, raft_peer_count(r2))
	assert_equal(0, rmr_has_peer(r2, 9))
	raft_free(r2)
	raft_wal_close(rw2)
	free(path)
