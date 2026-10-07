# wbuild: x64
import lib.testing
import libs.standard.distributed.raft_sim_harness
import libs.standard.distributed.raft_wire


void learner_drop(list[raft_msg*] out):
	for i in range(out.length): raft_msg_free(out[i])
	out.clear()


rsim* learner_cluster(int seed):
	rsim* c = rsim_new(3, seed, 0, 0, 0, seed)
	rsim_harden(c, 1, 1)
	assert1(rsim_run_until_leader(c, 200) >= 0)
	rsim_run(c, 20)
	return c


void learner_join(rsim* c, int id):
	list[int] voters = raft_peers_except(id, id)
	raft* node = raft_new_learner(id, voters, 150, 300, 50, 8800 + id)
	voters.free()
	raft_set_prevote(node, 1)
	assert_equal(id, rsim_add_node(c, node))
	int leader = rsim_leader(c)
	rsim_route_accepted(c, leader, raft_propose_add_learner(c.nodes[leader - 1], id, sim_now(c.net), c.out))


void test_partitioned_learner_preserves_voter_quorum_and_safe_promotion():
	rsim* c = learner_cluster(5911)
	int lid = rsim_leader(c)
	raft* leader = c.nodes[lid - 1]
	learner_join(c, 4)
	rsim_partition_from_all(c, 4)
	rsim_run(c, 30)
	assert_equal(2, raft_majority(leader))
	assert_equal(0, raft_is_voter(leader, 4))
	assert_equal(0, raft_learner_ready(leader, 4))
	assert_equal(0, raft_propose_promote_learner(leader, 4, sim_now(c.net), c.out))
	# A checked sequential write history keeps committing with the learner absent.
	for i in range(8):
		rsim_propose(c, lid, c"write")
		rsim_run(c, 10)
		assert_equal(raft_last_index(leader), raft_commit_int(leader))
		assert_equal(0, raft_is_voter(c.nodes[3], 4))
		assert_equal(raft_follower, raft_state(c.nodes[3]))
	for id in range(1, 4): sim_heal(c.net, id, 4)
	rsim_run(c, 60)
	assert_equal(1, raft_learner_ready(leader, 4))
	assert_equal(raft_last_index(leader), raft_last_index(c.nodes[3]))
	int token = raft_read_begin(leader, sim_now(c.net), 500, c.out)
	assert1(token > 0)
	learner_drop(c.out)
	rsim_route_accepted(c, lid, raft_propose_promote_learner(leader, 4, sim_now(c.net), c.out))
	int index = 0
	assert_equal(-1, raft_read_poll(leader, token, sim_now(c.net), raft_commit_int(leader), &index))
	assert_equal(3, raft_majority(leader))
	rsim_run(c, 30)
	assert_equal(1, raft_is_voter(c.nodes[3], 4))
	assert_equal(0, raft_config_pending(leader))
	rsim_free(c)


void test_learners_never_supply_read_or_write_majorities_or_term_claims():
	rsim* c = learner_cluster(5912)
	int lid = rsim_leader(c)
	raft* leader = c.nodes[lid - 1]
	learner_join(c, 4)
	rsim_run(c, 30)
	int committed = raft_commit_int(leader)
	for id in range(1, 4):
		if (id != lid): rsim_partition_from_all(c, id)
	int token = raft_read_begin(leader, sim_now(c.net), 100, c.out)
	assert1(token > 0)
	rsim_route_out(c)
	rsim_propose(c, lid, c"blocked")
	rsim_run(c, 5)
	assert_equal(committed, raft_commit_int(leader))
	assert_equal(raft_last_index(leader), raft_last_index(c.nodes[3]))
	int index = 0
	assert_equal(0, raft_read_poll(leader, token, sim_now(c.net), committed, &index))
	assert_equal(0, leader.read_acks.length)
	int term = raft_u64_as_int(leader.current_term)
	u64* higher = u64_new_int(term + 50)
	for type in range(7):
		raft_msg* claim = raft_msg_new(type, 4, lid, higher)
		claim.vote_granted = 1
		claim.success = 1
		raft_on_msg(leader, claim, sim_now(c.net), c.out)
		raft_msg_free(claim)
	assert_equal(term, raft_u64_as_int(leader.current_term))
	assert_equal(raft_leader, leader.state)
	assert_equal(0, leader.read_acks.length)
	u64_free(higher)
	rsim_free(c)


void test_new_leader_cannot_change_voters_before_current_term_commit():
	rsim* c = learner_cluster(5913)
	int old = rsim_leader(c)
	learner_join(c, 4)
	rsim_run(c, 30)
	# Isolate the old leader after its promotion is appended, before routing it.
	raft* former = c.nodes[old - 1]
	assert_equal(1, raft_propose_promote_learner(former, 4, sim_now(c.net), c.out))
	learner_drop(c.out)
	rsim_partition_from_all(c, old)
	# No automatic no-op: the successor has to establish its term explicitly.
	for i in range(c.nodes.length): raft_set_noop_on_win(c.nodes[i], 0)
	rsim_run(c, 100)
	int lid = rsim_leader(c)
	assert1(lid != old && lid > 0)
	raft* leader = c.nodes[lid - 1]
	assert_equal(0, raft_membership_ready(leader))
	assert_equal(0, raft_propose_promote_learner(leader, 4, sim_now(c.net), c.out))
	assert_equal(0, raft_propose_remove_server(leader, old, sim_now(c.net), c.out))
	rsim_propose(c, lid, c"establish-term")
	rsim_run(c, 30)
	assert_equal(1, raft_membership_ready(leader))
	assert_equal(1, raft_learner_ready(leader, 4))
	rsim_route_accepted(c, lid, raft_propose_remove_server(leader, old, sim_now(c.net), c.out))
	rsim_run(c, 30)
	assert_equal(0, raft_is_peer(leader, old))
	u64* stale_term = u64_new_int(raft_u64_as_int(leader.current_term) + 100)
	raft_msg* stale = raft_msg_new(raft_msg_vote_req, old, lid, stale_term)
	raft_on_msg(leader, stale, sim_now(c.net), c.out)
	assert_equal(raft_leader, leader.state)
	assert1(u64_cmp(leader.current_term, stale_term) < 0)
	raft_msg_free(stale)
	u64_free(stale_term)
	rsim_free(c)


void learner_config_entry(raft* r, int op, int id):
	char* cmd = raft_config_encode(op, id)
	raft_entry* e = raft_entry_new_kind(r.current_term, cmd, 5, raft_entry_kind_config())
	r.log.push(e)
	raft_note_entry_appended(r, raft_last_index(r), e)
	free(cmd)


void test_learner_recovery_snapshot_boundary_and_multiple_rollback():
	char* path = strjoin(c"bin/learner-recovery-", itoa(__word_size__))
	create_file(path, 420)
	list[int] peers = new list[int]
	peers.push(2)
	peers.push(3)
	raft* r = raft_new(1, peers, 50, 100, 10, 5914)
	u64_set_int(r.current_term, 1)
	learner_config_entry(r, raft_config_op_learner, 4)
	learner_config_entry(r, raft_config_op_add, 4)
	u64_set_int(r.commit_index, 2)
	raft_note_commit_advanced(r)
	# Snapshot before the already-committed promotion is applied: role must be
	# learner at index 1 even though the live configuration makes it a voter.
	raft_entry* applied = raft_pop_apply(r)
	assert_equal(raft_entry_kind_config(), applied.kind)
	assert_equal(1, raft_take_snapshot(r, c"state", 5))
	assert_equal(-5, r.snap_config[r.snap_config.length - 1])
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	assert1(raft_wal_sync(rw, r) > 0)
	raft_free(r)
	raft_wal_close(rw)
	rw = raft_wal_open(path)
	r = raft_wal_recover(rw, 1, peers, 50, 100, 10, 5915)
	assert_equal(1, raft_is_voter(r, 4))
	assert_equal(1, raft_config_pending(r))
	# A later uncommitted learner entry does not hide the earlier promotion
	# when a recovery-time truncation rolls back both entries together.
	learner_config_entry(r, raft_config_op_learner, 5)
	raft_note_truncated_to(r, 1)
	while (r.log.length > 0): raft_entry_free(r.log.pop())
	assert_equal(0, raft_is_voter(r, 4))
	assert_equal(1, raft_is_peer(r, 4))
	assert_equal(0, raft_is_peer(r, 5))
	assert_equal(0, raft_config_pending(r))
	assert1(raft_wal_sync(rw, r) > 0)
	raft_free(r)
	raft_wal_close(rw)
	rw = raft_wal_open(path)
	r = raft_wal_recover(rw, 1, peers, 50, 100, 10, 5916)
	assert_equal(0, raft_is_voter(r, 4))
	assert_equal(1, raft_is_peer(r, 4))
	raft_free(r)
	raft_wal_close(rw)
	peers.free()
	free(path)


void test_empty_learner_recovery_cannot_campaign_and_config_validation():
	char* path = strjoin(c"bin/empty-learner-", itoa(__word_size__))
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	list[int] voters = new list[int]
	voters.push(1)
	raft* r = raft_wal_recover_learner(rw, 2, voters, 50, 100, 10, 5917)
	list[raft_msg*] out = new list[raft_msg*]
	raft_start(r, 0)
	raft_tick(r, 1000, out)
	assert_equal(0, out.length)
	assert_equal(raft_follower, r.state)
	assert_equal(0, raft_u64_as_int(r.current_term))
	list[int] cfg = new list[int]
	cfg.push(1)
	cfg.push(-3)
	assert_equal(1, raft_config_valid(cfg))
	cfg.push(2)
	assert_equal(0, raft_config_valid(cfg))
	cfg.clear()
	cfg.push(-3)
	assert_equal(0, raft_config_valid(cfg))
	cfg.clear()
	cfg.push(1)
	cfg.push(2147483647)
	assert_equal(0, raft_config_valid(cfg))
	cfg.free()
	out.free()
	raft_free(r)
	raft_wal_close(rw)
	voters.free()
	free(path)


void test_learner_snapshot_wire_and_invalid_identity_metadata():
	u64* term = u64_new_int(1)
	raft_msg* m = raft_msg_new(raft_msg_install_snapshot, 1, 2, term)
	m.snap_config.push(1)
	m.snap_config.push(-3)
	int size = raft_wire_size(m)
	char* encoded = malloc(size)
	raft_wire_encode(m, encoded)
	raft_msg* decoded = raft_wire_decode(encoded, size)
	assert1(cast(int, decoded) != 0)
	assert_equal(-3, decoded.snap_config[1])
	raft_msg_free(decoded)
	# Same identity appearing as voter and learner must fail closed.
	store_le32(encoded + 17 + 28, 2)
	assert_equal(0, cast(int, raft_wire_decode(encoded, size)))
	# Reserved minimum signed token decodes to an out-of-range ID.
	store_le32(encoded + 17 + 28, 1)
	store_le32(encoded + 17 + 32, cast(int, 0x80000000))
	assert_equal(0, cast(int, raft_wire_decode(encoded, size)))
	free(encoded)
	raft_msg_free(m)
	u64_free(term)
