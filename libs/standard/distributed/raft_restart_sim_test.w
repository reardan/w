# wbuild: x64
import lib.testing
import libs.standard.distributed.raft_wal
import libs.standard.distributed.sim


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
0 drop), and the checked step loop asserts that no two same-term
leaders ever coexist. Message ownership follows raft_sim_test.w:
delivered payloads are freed after raft_on_msg, send-drops on the
spot, partition-drops when the dropped queue drains, and anything
still in flight at teardown during rc_free's drain. Messages that
come due for a crashed node are freed undelivered — the process they
were addressed to is gone.
*/


# ---- u64 conveniences ---------------------------------------------------------

int rc_term_int(raft* r):
	u64* t = u64_new()
	raft_term(r, t)
	int v = raft_u64_as_int(t)
	u64_free(t)
	return v


int rc_commit_int(raft* r):
	u64* ci = u64_new()
	raft_commit_index(r, ci)
	int v = raft_u64_as_int(ci)
	u64_free(ci)
	return v


void rc_free_msgs(list[raft_msg*] out):
	while (out.length > 0):
		raft_msg* m = out.pop()
		raft_msg_free(m)


raft_msg* rc_make_vote_req(int from, int to, int term, int last_index, int last_term):
	u64* t = u64_new_int(term)
	raft_msg* m = raft_msg_new(raft_msg_vote_req(), from, to, t)
	u64_free(t)
	u64_set_int(m.last_log_index, last_index)
	u64_set_int(m.last_log_term, last_term)
	return m


# Per-node per-target wal path (bin/ is gitignored scratch space).
char* rc_path(char* name, int id):
	char* a = strjoin(c"bin/rrs_t", itoa(__word_size__))
	char* b = strjoin(a, c"_")
	char* d = strjoin(b, name)
	char* e = strjoin(d, c"_")
	char* f = strjoin(e, itoa(id))
	char* path = strjoin(f, c".log")
	free(f)
	free(e)
	free(d)
	free(b)
	free(a)
	return path


# ---- cluster driver -------------------------------------------------------------

struct rcluster:
	int n                 # node count; ids are 1..n at nodes[id - 1]
	list[raft*] nodes     # dangling while alive[i] == 0
	list[raft_wal*] wals  # closed while alive[i] == 0; the file survives
	list[char*] paths
	list[int] alive
	sim_net* net


list[int] rc_peers(int n, int id):
	list[int] peers = new list[int]
	int p = 1
	while (p <= n):
		if (p != id):
			peers.push(p)
		p = p + 1
	return peers


# n rafts with ids 1..n, election window 150..300 ms, heartbeat 50 ms,
# each paired with a fresh wal (files reset so reruns start clean).
rcluster* rc_new(int n, char* name, int sim_seed, int min_delay, int max_delay, int drop_per_mille, int raft_seed_base):
	rcluster* c = new rcluster()
	c.n = n
	c.net = sim_new(sim_seed, min_delay, max_delay, drop_per_mille)
	c.nodes = new list[raft*]
	c.wals = new list[raft_wal*]
	c.paths = new list[char*]
	c.alive = new list[int]
	int id = 1
	while (id <= n):
		char* path = rc_path(name, id)
		create_file(path, 420)
		raft_wal* rw = raft_wal_open(path)
		assert1(cast(int, rw) != 0)
		raft* r = raft_new(id, rc_peers(n, id), 150, 300, 50, raft_seed_base + id)
		raft_start(r, sim_now(c.net))
		c.nodes.push(r)
		c.wals.push(rw)
		c.paths.push(path)
		c.alive.push(1)
		id = id + 1
	return c


void rc_route_out(rcluster* c, list[raft_msg*] out):
	int i = 0
	while (i < out.length):
		raft_msg* m = out[i]
		if (sim_send(c.net, m.from, m.to, cast(char*, m)) == 0):
			raft_msg_free(m)
		i = i + 1
	out.clear()


void rc_drain_dropped(rcluster* c):
	char* d = sim_take_dropped(c.net)
	while (d != 0):
		raft_msg_free(cast(raft_msg*, d))
		d = sim_take_dropped(c.net)


# Deliver every due packet: live destinations dispatch, persist, and
# reply; a packet due for a crashed node is freed undelivered.
void rc_deliver_due(rcluster* c):
	int from = 0
	int to = 0
	list[raft_msg*] out = new list[raft_msg*]
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg* m = cast(raft_msg*, p)
		if (c.alive[to - 1] == 1):
			raft* dest = c.nodes[to - 1]
			raft_on_msg(dest, m, sim_now(c.net), out)
			raft_wal_sync(c.wals[to - 1], dest)   # persist before replying
			rc_route_out(c, out)
		raft_msg_free(m)
		p = sim_take_due(c.net, &from, &to)
	rc_drain_dropped(c)


# One 10 ms round: tick every live node (persisting, then routing what
# it emits), deliver everything due, advance the clock.
void rc_step(rcluster* c):
	list[raft_msg*] out = new list[raft_msg*]
	int i = 0
	while (i < c.n):
		if (c.alive[i] == 1):
			raft_tick(c.nodes[i], sim_now(c.net), out)
			raft_wal_sync(c.wals[i], c.nodes[i])
			rc_route_out(c, out)
		i = i + 1
	rc_deliver_due(c)
	sim_advance(c.net, 10)


# Never two live leaders in the SAME term; different terms are a legal
# transient (a stale partitioned leader).
void rc_assert_no_same_term_leaders(rcluster* c):
	u64* ti = u64_new()
	u64* tj = u64_new()
	int i = 0
	while (i < c.n):
		if (c.alive[i] == 1 && raft_state(c.nodes[i]) == raft_leader()):
			int j = i + 1
			while (j < c.n):
				if (c.alive[j] == 1 && raft_state(c.nodes[j]) == raft_leader()):
					raft_term(c.nodes[i], ti)
					raft_term(c.nodes[j], tj)
					assert_equal(0, u64_eq(ti, tj))
				j = j + 1
		i = i + 1
	u64_free(ti)
	u64_free(tj)


# Checked stepping: the split-brain rail holds at every round.
void rc_run_steps(rcluster* c, int k):
	int i = 0
	while (i < k):
		rc_step(c)
		rc_assert_no_same_term_leaders(c)
		i = i + 1


# The id of the unique live leader at the highest term among leaders,
# or 0 - 1 when none leads or that highest term is shared.
int rc_leader(rcluster* c):
	u64* best = u64_new()
	u64* t = u64_new()
	int found = 0
	int dup = 0
	int leader_id = 0 - 1
	int i = 0
	while (i < c.n):
		if (c.alive[i] == 1 && raft_state(c.nodes[i]) == raft_leader()):
			raft_term(c.nodes[i], t)
			if (found == 0):
				found = 1
				u64_copy(best, t)
				leader_id = i + 1
			else:
				int cmp = u64_cmp(t, best)
				if (cmp > 0):
					u64_copy(best, t)
					leader_id = i + 1
					dup = 0
				if (cmp == 0):
					dup = 1
		i = i + 1
	u64_free(best)
	u64_free(t)
	if (found == 1 && dup == 0):
		return leader_id
	return 0 - 1


int rc_run_until_leader(rcluster* c, int max_steps):
	int steps = 0
	while (steps < max_steps):
		if (rc_leader(c) != (0 - 1)):
			return steps
		rc_step(c)
		rc_assert_no_same_term_leaders(c)
		steps = steps + 1
	if (rc_leader(c) != (0 - 1)):
		return steps
	return 0 - 1


# Propose on node id (asserting it accepts), persist, then route.
void rc_propose(rcluster* c, int id, char* command):
	assert_equal(1, c.alive[id - 1])
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, raft_propose(c.nodes[id - 1], command, strlen(command), sim_now(c.net), out))
	raft_wal_sync(c.wals[id - 1], c.nodes[id - 1])
	rc_route_out(c, out)


void rc_partition_from_all(rcluster* c, int id):
	int i = 1
	while (i <= c.n):
		if (i != id):
			sim_partition(c.net, id, i)
		i = i + 1


void rc_heal_all(rcluster* c):
	int a = 1
	while (a <= c.n):
		int b = a + 1
		while (b <= c.n):
			sim_heal(c.net, a, b)
			b = b + 1
		a = a + 1


# Every node alive and its log identical to node 1's, entry by entry.
void rc_assert_logs_identical(rcluster* c):
	assert_equal(1, c.alive[0])
	raft* first = c.nodes[0]
	int i = 1
	while (i < c.n):
		assert_equal(1, c.alive[i])
		raft* other = c.nodes[i]
		assert_equal(raft_log_length(first), raft_log_length(other))
		int k = 1
		while (k <= raft_log_length(first)):
			raft_entry* mine = raft_log_at(first, k)
			raft_entry* theirs = raft_log_at(other, k)
			assert_equal(1, u64_eq(mine.term, theirs.term))
			assert_strings_equal(mine.command, theirs.command)
			k = k + 1
		i = i + 1


# Crash node id: one last sync (the step loop already synced after the
# last event, so this is usually a no-op), then the process dies — the
# raft is freed and the adapter closed. The wal FILE survives.
void rc_crash(rcluster* c, int id):
	assert_equal(1, c.alive[id - 1])
	raft_wal_sync(c.wals[id - 1], c.nodes[id - 1])
	raft_free(c.nodes[id - 1])
	raft_wal_close(c.wals[id - 1])
	c.alive[id - 1] = 0


# Rebuild node id from its wal: reopen the adapter (replaying the
# shadow), recover a fresh raft from the records, and start it at the
# sim's current time. Recovery replays exactly what was persisted, so
# an immediate sync appends nothing.
void rc_rebuild(rcluster* c, int id, int seed):
	assert_equal(0, c.alive[id - 1])
	raft_wal* rw = raft_wal_open(c.paths[id - 1])
	assert1(cast(int, rw) != 0)
	raft* r = raft_wal_recover(rw, id, rc_peers(c.n, id), 150, 300, 50, seed)
	raft_start(r, sim_now(c.net))
	c.wals[id - 1] = rw
	c.nodes[id - 1] = r
	c.alive[id - 1] = 1
	assert_equal(0, raft_wal_sync(rw, r))


# Drain the wire, then free live rafts, close live adapters (crashed
# nodes' adapters were closed at crash time) and free the paths.
void rc_free(rcluster* c):
	sim_advance(c.net, 1000000)
	int from = 0
	int to = 0
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg_free(cast(raft_msg*, p))
		p = sim_take_due(c.net, &from, &to)
	rc_drain_dropped(c)
	int i = 0
	while (i < c.n):
		if (c.alive[i] == 1):
			raft_free(c.nodes[i])
			raft_wal_close(c.wals[i])
		free(c.paths[i])
		i = i + 1
	sim_free(c.net)
	free(c)


# ---- crash, rebuild, rejoin, converge ----------------------------------------------

void test_restart_rejoin_converges():
	rcluster* c = rc_new(3, c"rejoin", 1001, 0, 0, 0, 100)
	int steps = rc_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = rc_leader(c)
	rc_propose(c, lid, c"a")
	rc_propose(c, lid, c"b")
	rc_run_steps(c, 50)
	int i = 0
	while (i < 3):
		assert_equal(2, rc_commit_int(c.nodes[i]))
		i = i + 1
	# crash a follower; its wal holds term, vote and both entries
	int victim = 1
	if (victim == lid):
		victim = 2
	rc_crash(c, victim)
	rc_run_steps(c, 20)
	# the remaining majority keeps committing without it
	rc_propose(c, lid, c"c")
	rc_run_steps(c, 50)
	assert_equal(3, rc_commit_int(c.nodes[lid - 1]))
	# rebuild the victim from its wal: the persisted prefix is back,
	# volatile commit re-derives once the leader's appends arrive
	rc_rebuild(c, victim, 900 + victim)
	assert_equal(2, raft_log_length(c.nodes[victim - 1]))
	assert_equal(0, rc_commit_int(c.nodes[victim - 1]))
	assert_equal(raft_follower(), raft_state(c.nodes[victim - 1]))
	rc_run_steps(c, 100)
	# all three logs identical: [a, b, c] committed everywhere, one
	# leader at the highest term
	rc_assert_logs_identical(c)
	i = 0
	while (i < 3):
		raft* r = c.nodes[i]
		assert_equal(3, raft_log_length(r))
		assert_equal(3, rc_commit_int(r))
		raft_entry* e1 = raft_log_at(r, 1)
		assert_strings_equal(c"a", e1.command)
		raft_entry* e2 = raft_log_at(r, 2)
		assert_strings_equal(c"b", e2.command)
		raft_entry* e3 = raft_log_at(r, 3)
		assert_strings_equal(c"c", e3.command)
		i = i + 1
	assert1(rc_leader(c) >= 1)
	rc_free(c)


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
	assert_equal(1, rc_term_int(n2))
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
	assert_equal(1, rc_term_int(n2b))
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
	rcluster* c = rc_new(3, c"stepdown", 5005, 0, 0, 0, 500)
	int steps = rc_run_until_leader(c, 200)
	assert1(steps >= 0)
	int old_lid = rc_leader(c)
	rc_propose(c, old_lid, c"x")
	rc_run_steps(c, 50)
	int i = 0
	while (i < 3):
		assert_equal(1, rc_commit_int(c.nodes[i]))
		i = i + 1
	int old_term = rc_term_int(c.nodes[old_lid - 1])
	# crash the leader and rebuild it immediately, but behind a
	# partition: it recovers as a follower still on its old term
	rc_crash(c, old_lid)
	rc_rebuild(c, old_lid, 700 + old_lid)
	rc_partition_from_all(c, old_lid)
	assert_equal(raft_follower(), raft_state(c.nodes[old_lid - 1]))
	assert_equal(old_term, rc_term_int(c.nodes[old_lid - 1]))
	assert_equal(1, raft_log_length(c.nodes[old_lid - 1]))
	# the connected pair elects a fresh leader at a higher term (the
	# dark ex-leader chases terms as a candidate but can never win)
	int k = 0
	int new_lid = 0 - 1
	while (k < 300 && new_lid < 0):
		rc_step(c)
		rc_assert_no_same_term_leaders(c)
		int cand = rc_leader(c)
		if (cand != (0 - 1) && cand != old_lid):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	assert1(new_lid != old_lid)
	assert1(rc_term_int(c.nodes[new_lid - 1]) > old_term)
	rc_propose(c, new_lid, c"y")
	rc_run_steps(c, 30)
	assert_equal(2, rc_commit_int(c.nodes[new_lid - 1]))
	# the rebuilt ex-leader's commit is volatile state: it restarted at
	# 0 and, still partitioned, has heard no leader_commit since
	assert_equal(0, rc_commit_int(c.nodes[old_lid - 1]))
	rc_heal_all(c)
	rc_run_steps(c, 300)
	# the ex-leader ends a follower; every log is [x, y], committed
	assert_equal(raft_follower(), raft_state(c.nodes[old_lid - 1]))
	rc_assert_logs_identical(c)
	i = 0
	while (i < 3):
		raft* r = c.nodes[i]
		assert_equal(2, raft_log_length(r))
		assert_equal(2, rc_commit_int(r))
		raft_entry* e1 = raft_log_at(r, 1)
		assert_strings_equal(c"x", e1.command)
		raft_entry* e2 = raft_log_at(r, 2)
		assert_strings_equal(c"y", e2.command)
		i = i + 1
	int final_lid = rc_leader(c)
	assert1(final_lid >= 1)
	assert1(final_lid != old_lid)
	rc_free(c)
