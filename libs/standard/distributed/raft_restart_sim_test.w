# wbuild: x64
import lib.testing
import libs.standard.distributed.raft_sim_harness


/*
Crash/restart raft clusters through the deterministic simulator: every
node is paired with a raft_wal adapter, raft_wal_sync runs after each
tick/dispatch (persist before the replies hit the wire), a crash is
raft_free + adapter close with the wal file kept, and a rebuild is
raft_wal_open + raft_wal_recover + raft_start at the sim's current
time. The scenarios assert that the rebuilt node rejoins and the
cluster converges, that a persisted vote blocks a same-term double
grant after a restart, and that a restarted ex-leader ends up a
follower on the merged history.

Every scenario is seeded and deterministic (clean network: 0 delay,
0 drop) and runs on raft_sim_harness.w (message ownership, including
packets due for a crashed node, is documented there).
*/


void rc_free_msgs(list[raft_msg*] out):
	while (out.length > 0):
		raft_msg* m = out.pop()
		raft_msg_free(m)


raft_msg* rc_make_vote_req(int from, int to, int term, int last_index, int last_term):
	u64* t = u64_new_int(term)
	raft_msg* m = raft_msg_new(raft_msg_vote_req, from, to, t)
	u64_free(t)
	u64_set_int(m.last_log_index, last_index)
	u64_set_int(m.last_log_term, last_term)
	return m


# Per-node per-target wal path (bin/ is gitignored scratch space).
char* rc_path(char* name, int id):
	string path = f"bin/rrs_t{__word_size__}_{name}_{id}.log"
	return path.data


# ---- cluster driver (raft_sim_harness.w with a wal per node) ---------------------

rsim* rc_new(int n, char* name, int sim_seed, int min_delay, int max_delay, int drop_per_mille, int raft_seed_base):
	rsim* c = rsim_new(n, sim_seed, min_delay, max_delay, drop_per_mille, raft_seed_base)
	for id in range(1, n + 1):
		rsim_attach_wal(c, id, rc_path(name, id))
	return c


# ---- crash, rebuild, rejoin, converge ----------------------------------------------

void test_restart_rejoin_converges():
	rsim* c = rc_new(3, c"rejoin", 1001, 0, 0, 0, 100)
	int steps = rsim_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = rsim_leader(c)
	rsim_propose(c, lid, c"a")
	rsim_propose(c, lid, c"b")
	rsim_run(c, 50)
	int i = 0
	while (i < 3):
		assert_equal(2, raft_commit_int(c.nodes[i]))
		i = i + 1
	# crash a follower; its wal holds term, vote and both entries
	int victim = 1
	if (victim == lid):
		victim = 2
	rsim_crash(c, victim)
	rsim_run(c, 20)
	# the remaining majority keeps committing without it
	rsim_propose(c, lid, c"c")
	rsim_run(c, 50)
	assert_equal(3, raft_commit_int(c.nodes[lid - 1]))
	# rebuild the victim from its wal: the persisted prefix is back,
	# volatile commit re-derives once the leader's appends arrive
	rsim_rebuild(c, victim, 900 + victim)
	assert_equal(2, raft_log_length(c.nodes[victim - 1]))
	assert_equal(0, raft_commit_int(c.nodes[victim - 1]))
	assert_equal(raft_follower, raft_state(c.nodes[victim - 1]))
	rsim_run(c, 100)
	# all three logs identical: [a, b, c] committed everywhere, one
	# leader at the highest term
	rsim_assert_logs_identical(c)
	i = 0
	while (i < 3):
		raft* r = c.nodes[i]
		assert_equal(3, raft_log_length(r))
		assert_equal(3, raft_commit_int(r))
		raft_entry* e1 = raft_log_at(r, 1)
		assert_strings_equal(c"a", e1.command)
		raft_entry* e2 = raft_log_at(r, 2)
		assert_strings_equal(c"b", e2.command)
		raft_entry* e3 = raft_log_at(r, 3)
		assert_strings_equal(c"c", e3.command)
		i = i + 1
	assert1(rsim_leader(c) >= 1)
	rsim_free(c)


# ---- a persisted vote blocks a same-term double grant --------------------------------

void test_restart_preserves_vote_no_double_vote():
	# Hand-shuttled instead of sim-routed for exact determinism: an
	# election is left hanging mid-flight, the voter crashes, and its
	# restored vote must deny a rival's same-term request. Without the
	# wal the restarted node would happily grant twice in one term —
	# the classic split-brain seed.
	char* path = rc_path(c"vote", 2)
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	raft* n2 = raft_new(2, list[int]{1, 3}, 150, 300, 50, 7)
	raft_start(n2, 0)
	list[raft_msg*] out = new list[raft_msg*]
	# candidate 1 solicits in term 1 and node 2 grants; the reply is
	# never delivered, so the election stays unresolved
	raft_msg* req = rc_make_vote_req(1, 2, 1, 0, 0)
	raft_on_msg(n2, req, 10, out)
	raft_msg_free(req)
	assert_equal(1, out.length)
	raft_msg* grant = out[0]
	assert_equal(1, grant.vote_granted)
	rc_free_msgs(out)
	assert_equal(1, raft_term_int(n2))
	assert_equal(1, raft_voted_for(n2))
	# persist (term 1 + vote for 1 in one STATE record), then crash
	assert_equal(1, raft_wal_sync(rw, n2))
	raft_free(n2)
	raft_wal_close(rw)
	# rebuild: term and vote survived the crash
	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	raft* n2b = raft_wal_recover(rw2, 2, list[int]{1, 3}, 150, 300, 50, 8)
	raft_start(n2b, 20)
	assert_equal(1, raft_term_int(n2b))
	assert_equal(1, raft_voted_for(n2b))
	# rival candidate 3 asks at the SAME term: denied
	raft_msg* rival = rc_make_vote_req(3, 2, 1, 0, 0)
	raft_on_msg(n2b, rival, 30, out)
	raft_msg_free(rival)
	assert_equal(1, out.length)
	raft_msg* deny = out[0]
	assert_equal(0, deny.vote_granted)
	assert_equal(1, raft_u64_as_int(deny.term))
	rc_free_msgs(out)
	assert_equal(1, raft_voted_for(n2b))
	# the original candidate retrying the same term is still granted
	# (idempotent re-grant), and nothing new needs persisting
	raft_msg* retry = rc_make_vote_req(1, 2, 1, 0, 0)
	raft_on_msg(n2b, retry, 40, out)
	raft_msg_free(retry)
	assert_equal(1, out.length)
	raft_msg* regrant = out[0]
	assert_equal(1, regrant.vote_granted)
	rc_free_msgs(out)
	assert_equal(0, raft_wal_sync(rw2, n2b))
	raft_free(n2b)
	raft_wal_close(rw2)
	free(path)


# ---- a restarted leader ends up a follower --------------------------------------------

void test_restarted_leader_steps_down():
	rsim* c = rc_new(3, c"stepdown", 5005, 0, 0, 0, 500)
	int steps = rsim_run_until_leader(c, 200)
	assert1(steps >= 0)
	int old_lid = rsim_leader(c)
	rsim_propose(c, old_lid, c"x")
	rsim_run(c, 50)
	int i = 0
	while (i < 3):
		assert_equal(1, raft_commit_int(c.nodes[i]))
		i = i + 1
	int old_term = raft_term_int(c.nodes[old_lid - 1])
	# crash the leader and rebuild it immediately, but behind a
	# partition: it recovers as a follower still on its old term
	rsim_crash(c, old_lid)
	rsim_rebuild(c, old_lid, 700 + old_lid)
	rsim_partition_from_all(c, old_lid)
	assert_equal(raft_follower, raft_state(c.nodes[old_lid - 1]))
	assert_equal(old_term, raft_term_int(c.nodes[old_lid - 1]))
	assert_equal(1, raft_log_length(c.nodes[old_lid - 1]))
	# the connected pair elects a fresh leader at a higher term (the
	# dark ex-leader chases terms as a candidate but can never win)
	int k = 0
	int new_lid = 0 - 1
	while (k < 300 && new_lid < 0):
		rsim_step(c)
		rafts_assert_no_same_term_leaders(c.nodes)
		int cand = rsim_leader(c)
		if (cand != (0 - 1) && cand != old_lid):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	assert1(new_lid != old_lid)
	assert1(raft_term_int(c.nodes[new_lid - 1]) > old_term)
	rsim_propose(c, new_lid, c"y")
	rsim_run(c, 30)
	assert_equal(2, raft_commit_int(c.nodes[new_lid - 1]))
	# the rebuilt ex-leader's commit is volatile state: it restarted at
	# 0 and, still partitioned, has heard no leader_commit since
	assert_equal(0, raft_commit_int(c.nodes[old_lid - 1]))
	rsim_heal_all(c)
	rsim_run(c, 300)
	# the ex-leader ends a follower; every log is [x, y], committed
	assert_equal(raft_follower, raft_state(c.nodes[old_lid - 1]))
	rsim_assert_logs_identical(c)
	i = 0
	while (i < 3):
		raft* r = c.nodes[i]
		assert_equal(2, raft_log_length(r))
		assert_equal(2, raft_commit_int(r))
		raft_entry* e1 = raft_log_at(r, 1)
		assert_strings_equal(c"x", e1.command)
		raft_entry* e2 = raft_log_at(r, 2)
		assert_strings_equal(c"y", e2.command)
		i = i + 1
	int final_lid = rsim_leader(c)
	assert1(final_lid >= 1)
	assert1(final_lid != old_lid)
	rsim_free(c)
