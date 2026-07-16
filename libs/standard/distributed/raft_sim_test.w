# wbuild: x64
import lib.testing
import libs.standard.distributed.raft
import libs.standard.distributed.sim


/*
Multi-node raft clusters driven through the deterministic network
simulator (docs/projects/distributed.md, phase 3 payoff): elections and
log convergence under seeded loss, delay and partitions. Every scenario
is a pure function of its seeds — prng.w produces identical sequences
on every target — so each assertion is deterministic and the x64 twin
must reproduce the identical run.

Message ownership across the sim boundary: raft_msg* payloads travel
through sim.w as opaque char* (cast on send, cast back on delivery).
Every message is freed exactly once: delivered -> after raft_on_msg;
send-dropped (sim_send returned 0) -> immediately; partition-dropped ->
when the dropped queue is drained; still in flight at teardown ->
during cluster_free's drain.

Two leaders in DIFFERENT terms can transiently coexist (a partitioned
stale leader); that is not split brain. Split brain would be two
leaders in the SAME term, and cluster_assert_no_same_term_leaders
checks it never happens.
*/


# ---- u64 conveniences ---------------------------------------------------------

int cl_term_int(raft* r):
	u64* t = u64_new()
	raft_term(r, t)
	int v = raft_u64_as_int(t)
	u64_free(t)
	return v


int cl_commit_int(raft* r):
	u64* ci = u64_new()
	raft_commit_index(r, ci)
	int v = raft_u64_as_int(ci)
	u64_free(ci)
	return v


# Pop every pending apply on r, pushing the borrowed command pointers
# onto into (the log still owns the entries).
void cl_collect_applies(raft* r, list[char*] into):
	while (raft_pending_apply(r) == 1):
		raft_entry* e = raft_pop_apply(r)
		into.push(e.command)


# ---- cluster driver -------------------------------------------------------------

struct cluster:
	int n              # node count; ids are 1..n, node id lives at nodes[id - 1]
	list[raft*] nodes
	sim_net* net


# n rafts with ids 1..n (peers = every other id), election window
# 150..300 ms, heartbeat 50 ms. Each raft is seeded raft_seed_base + id
# so the nodes' election jitter differs; all are started at the sim's
# current time.
cluster* cluster_new(int n, int sim_seed, int min_delay, int max_delay, int drop_per_mille, int raft_seed_base):
	cluster* c = new cluster()
	c.n = n
	c.net = sim_new(sim_seed, min_delay, max_delay, drop_per_mille)
	c.nodes = new list[raft*]
	int id = 1
	while (id <= n):
		list[int] peers = new list[int]
		int p = 1
		while (p <= n):
			if (p != id):
				peers.push(p)
			p = p + 1
		raft* r = raft_new(id, peers, 150, 300, 50, raft_seed_base + id)
		raft_start(r, sim_now(c.net))
		c.nodes.push(r)
		id = id + 1
	return c


# Put every outbound message on the wire and drain the list. A message
# the drop roll loses stays ours (sim_send returned 0) and is freed on
# the spot.
void cluster_route_out(cluster* c, list[raft_msg*] out):
	int i = 0
	while (i < out.length):
		raft_msg* m = out[i]
		if (sim_send(c.net, m.from, m.to, cast(char*, m)) == 0):
			raft_msg_free(m)
		i = i + 1
	out.clear()


# Free every payload the sim dropped at delivery time (partitions).
void cluster_drain_dropped(cluster* c):
	char* d = sim_take_dropped(c.net)
	while (d != 0):
		raft_msg_free(cast(raft_msg*, d))
		d = sim_take_dropped(c.net)


# Deliver every due packet to its destination node, routing replies
# straight back onto the wire — a 0-delay reply comes due at the same
# virtual time and is delivered later in this same drain.
void cluster_deliver_due(cluster* c):
	int from = 0
	int to = 0
	list[raft_msg*] out = new list[raft_msg*]
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg* m = cast(raft_msg*, p)
		raft* dest = c.nodes[to - 1]
		raft_on_msg(dest, m, sim_now(c.net), out)
		raft_msg_free(m)
		cluster_route_out(c, out)
		p = sim_take_due(c.net, &from, &to)
	cluster_drain_dropped(c)


# One 10 ms round: tick every node (routing what it emits), deliver
# everything due at the current time, then advance the clock. Delivery
# before advance means a 0-delay message sent this round arrives this
# round.
void cluster_step(cluster* c):
	list[raft_msg*] out = new list[raft_msg*]
	int i = 0
	while (i < c.n):
		raft_tick(c.nodes[i], sim_now(c.net), out)
		cluster_route_out(c, out)
		i = i + 1
	cluster_deliver_due(c)
	sim_advance(c.net, 10)


void cluster_run_steps(cluster* c, int k):
	int i = 0
	while (i < k):
		cluster_step(c)
		i = i + 1


# Never two leaders in the SAME term (split brain); different-term
# leaders are a legal transient.
void cluster_assert_no_same_term_leaders(cluster* c):
	u64* ti = u64_new()
	u64* tj = u64_new()
	int i = 0
	while (i < c.n):
		if (raft_state(c.nodes[i]) == raft_leader()):
			int j = i + 1
			while (j < c.n):
				if (raft_state(c.nodes[j]) == raft_leader()):
					raft_term(c.nodes[i], ti)
					raft_term(c.nodes[j], tj)
					assert_equal(0, u64_eq(ti, tj))
				j = j + 1
		i = i + 1
	u64_free(ti)
	u64_free(tj)


# The id of the unique leader at the highest term among leaders, or
# 0 - 1 when no node leads or two leaders share that highest term.
int cluster_leader(cluster* c):
	u64* best = u64_new()
	u64* t = u64_new()
	int found = 0
	int dup = 0
	int leader_id = 0 - 1
	int i = 0
	while (i < c.n):
		raft* r = c.nodes[i]
		if (raft_state(r) == raft_leader()):
			raft_term(r, t)
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


# Step until cluster_leader finds one; steps taken, or 0 - 1 on timeout.
int cluster_run_until_leader(cluster* c, int max_steps):
	int steps = 0
	while (steps < max_steps):
		if (cluster_leader(c) != (0 - 1)):
			return steps
		cluster_step(c)
		steps = steps + 1
	if (cluster_leader(c) != (0 - 1)):
		return steps
	return 0 - 1


# Block id off from every other node (both directions per pair).
void cluster_partition_from_all(cluster* c, int id):
	int i = 1
	while (i <= c.n):
		if (i != id):
			sim_partition(c.net, id, i)
		i = i + 1


void cluster_heal_all(cluster* c):
	int a = 1
	while (a <= c.n):
		int b = a + 1
		while (b <= c.n):
			sim_heal(c.net, a, b)
			b = b + 1
		a = a + 1


# Every node's log identical to node 1's: same length, same terms, same
# commands, entry by entry.
void cluster_assert_logs_identical(cluster* c):
	raft* first = c.nodes[0]
	int i = 1
	while (i < c.n):
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


# Propose on node id (asserting it accepts, i.e. believes it leads) and
# put the resulting appends on the wire.
void cluster_propose(cluster* c, int id, char* command):
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, raft_propose(c.nodes[id - 1], command, strlen(command), sim_now(c.net), out))
	cluster_route_out(c, out)


# Drain the wire (in-flight and partition-dropped payloads are all
# raft_msgs we still own), then free the rafts and the sim. sim_free
# never frees payloads, so this drain is what prevents leaks.
void cluster_free(cluster* c):
	sim_advance(c.net, 1000000)
	int from = 0
	int to = 0
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg_free(cast(raft_msg*, p))
		p = sim_take_due(c.net, &from, &to)
	cluster_drain_dropped(c)
	int i = 0
	while (i < c.n):
		raft_free(c.nodes[i])
		i = i + 1
	sim_free(c.net)
	free(c)


# ---- elections ------------------------------------------------------------------

void test_election_clean_network():
	cluster* c = cluster_new(3, 1001, 0, 0, 0, 100)
	int steps = cluster_run_until_leader(c, 100)
	assert1(steps >= 0)
	int lid = cluster_leader(c)
	assert1(lid >= 1 && lid <= 3)
	cluster_assert_no_same_term_leaders(c)
	# a few extra rounds so heartbeats land and set the followers' hints
	cluster_run_steps(c, 10)
	assert_equal(lid, cluster_leader(c))
	int i = 0
	while (i < 3):
		if ((i + 1) != lid):
			assert_equal(raft_follower(), raft_state(c.nodes[i]))
			assert_equal(lid, raft_leader_hint(c.nodes[i]))
		i = i + 1
	cluster_free(c)


void test_election_with_loss_and_delay():
	# 5 nodes, 1..20 ms delays, 10% loss: a leader still emerges, and no
	# same-term leader pair ever appears at any step of the run
	cluster* c = cluster_new(5, 2002, 1, 20, 100, 200)
	int found = 0 - 1
	int steps = 0
	while (steps < 400):
		cluster_step(c)
		cluster_assert_no_same_term_leaders(c)
		if (found < 0 && cluster_leader(c) != (0 - 1)):
			found = steps
		steps = steps + 1
	assert1(found >= 0)
	cluster_free(c)


# ---- replication ----------------------------------------------------------------

void test_replication_commits_everywhere():
	cluster* c = cluster_new(3, 3003, 0, 0, 0, 300)
	int steps = cluster_run_until_leader(c, 100)
	assert1(steps >= 0)
	int lid = cluster_leader(c)
	cluster_propose(c, lid, c"a")
	cluster_propose(c, lid, c"b")
	cluster_propose(c, lid, c"c")
	cluster_run_steps(c, 50)
	list[char*] want = list[char*]{c"a", c"b", c"c"}
	int i = 0
	while (i < 3):
		raft* r = c.nodes[i]
		assert_equal(3, raft_log_length(r))
		assert_equal(3, cl_commit_int(r))
		list[char*] got = new list[char*]
		cl_collect_applies(r, got)
		assert_equal(3, got.length)
		int k = 0
		while (k < 3):
			assert_strings_equal(want[k], got[k])
			k = k + 1
		i = i + 1
	cluster_assert_logs_identical(c)
	cluster_free(c)


void test_no_commit_without_majority():
	cluster* c = cluster_new(3, 4004, 0, 0, 0, 400)
	int steps = cluster_run_until_leader(c, 100)
	assert1(steps >= 0)
	int old_lid = cluster_leader(c)
	raft* old_leader = c.nodes[old_lid - 1]
	cluster_partition_from_all(c, old_lid)
	cluster_propose(c, old_lid, c"lost")
	cluster_run_steps(c, 100)
	# the isolated leader keeps its throne (it cannot learn otherwise)
	# and the uncommitted entry, but the commit index stays 0
	assert_equal(raft_leader(), raft_state(old_leader))
	assert_equal(1, raft_log_length(old_leader))
	assert_equal(0, cl_commit_int(old_leader))
	# nothing applies anywhere
	int i = 0
	while (i < 3):
		assert_equal(0, raft_pending_apply(c.nodes[i]))
		i = i + 1
	# the two connected followers elected a new leader at a higher term,
	# and it never saw the isolated proposal
	int new_lid = cluster_leader(c)
	assert1(new_lid >= 1 && new_lid <= 3)
	assert1(new_lid != old_lid)
	assert1(cl_term_int(c.nodes[new_lid - 1]) > cl_term_int(old_leader))
	assert_equal(0, raft_log_length(c.nodes[new_lid - 1]))
	cluster_free(c)


void test_partition_heal_converges():
	# the scenario shape of test_no_commit_without_majority, continued
	# through a heal: the deposed leader's uncommitted entry is truncated
	# away and every log converges on the new leader's
	cluster* c = cluster_new(3, 5005, 0, 0, 0, 500)
	int steps = cluster_run_until_leader(c, 100)
	assert1(steps >= 0)
	int old_lid = cluster_leader(c)
	raft* old_leader = c.nodes[old_lid - 1]
	cluster_partition_from_all(c, old_lid)
	cluster_propose(c, old_lid, c"lost")
	int k = 0
	int new_lid = 0 - 1
	while (k < 200 && new_lid < 0):
		cluster_step(c)
		int cand = cluster_leader(c)
		if (cand != (0 - 1) && cand != old_lid):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	cluster_propose(c, new_lid, c"x")
	cluster_run_steps(c, 30)
	# committed on the majority pair while the old leader is dark
	assert_equal(1, cl_commit_int(c.nodes[new_lid - 1]))
	assert_equal(0, cl_commit_int(old_leader))
	cluster_heal_all(c)
	cluster_run_steps(c, 200)
	# the old leader stepped down on contact with the higher term
	assert_equal(raft_follower(), raft_state(old_leader))
	cluster_assert_logs_identical(c)
	int i = 0
	while (i < 3):
		raft* r = c.nodes[i]
		assert_equal(1, raft_log_length(r))
		assert_equal(1, cl_commit_int(r))
		raft_entry* e = raft_log_at(r, 1)
		assert_strings_equal(c"x", e.command)
		list[char*] got = new list[char*]
		cl_collect_applies(r, got)
		assert_equal(1, got.length)
		assert_strings_equal(c"x", got[0])
		i = i + 1
	cluster_free(c)


void test_leader_loss_reelection():
	cluster* c = cluster_new(3, 6006, 0, 0, 0, 600)
	int steps = cluster_run_until_leader(c, 100)
	assert1(steps >= 0)
	int old_lid = cluster_leader(c)
	int old_term = cl_term_int(c.nodes[old_lid - 1])
	cluster_partition_from_all(c, old_lid)
	int k = 0
	int new_lid = 0 - 1
	while (k < 200 && new_lid < 0):
		cluster_step(c)
		int cand = cluster_leader(c)
		if (cand != (0 - 1) && cand != old_lid):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	assert1(new_lid != old_lid)
	assert1(cl_term_int(c.nodes[new_lid - 1]) > old_term)
	# pin the new term with a committed entry so the deposed leader's
	# empty log keeps it from ever winning again after the heal
	cluster_propose(c, new_lid, c"pin")
	cluster_run_steps(c, 30)
	assert_equal(1, cl_commit_int(c.nodes[new_lid - 1]))
	cluster_heal_all(c)
	cluster_run_steps(c, 200)
	# the old leader rejoined as a follower; one leader stands, everyone
	# shares its term and hint, and the pinned entry is everywhere
	assert_equal(raft_follower(), raft_state(c.nodes[old_lid - 1]))
	int lid = cluster_leader(c)
	assert1(lid >= 1 && lid <= 3)
	assert1(lid != old_lid)
	int t_final = cl_term_int(c.nodes[lid - 1])
	int i = 0
	while (i < 3):
		assert_equal(t_final, cl_term_int(c.nodes[i]))
		assert_equal(lid, raft_leader_hint(c.nodes[i]))
		i = i + 1
	cluster_assert_logs_identical(c)
	cluster_free(c)


# ---- determinism ----------------------------------------------------------------

void test_seeded_replay_determinism():
	# the lossy 5-node scenario, run twice in lockstep from identical
	# seeds: after a fixed number of steps the two clusters agree on
	# leader, every node's term, log length and state
	cluster* a = cluster_new(5, 2002, 1, 20, 100, 200)
	cluster* b = cluster_new(5, 2002, 1, 20, 100, 200)
	int k = 0
	while (k < 250):
		cluster_step(a)
		cluster_step(b)
		k = k + 1
	assert_equal(cluster_leader(a), cluster_leader(b))
	int i = 0
	while (i < 5):
		assert_equal(cl_term_int(a.nodes[i]), cl_term_int(b.nodes[i]))
		assert_equal(raft_log_length(a.nodes[i]), raft_log_length(b.nodes[i]))
		assert_equal(raft_state(a.nodes[i]), raft_state(b.nodes[i]))
		i = i + 1
	cluster_free(a)
	cluster_free(b)
	# a different sim seed still elects (weak check only: no assertion
	# that the schedule differs)
	cluster* d = cluster_new(5, 7777, 1, 20, 100, 200)
	assert1(cluster_run_until_leader(d, 400) >= 0)
	cluster_free(d)


# ---- asymmetric partitions ---------------------------------------------------------

void test_five_node_two_partitions():
	cluster* c = cluster_new(5, 8008, 0, 0, 0, 800)
	# {1, 2} vs {3, 4, 5}: block every cross pair before any election
	int a = 1
	while (a <= 2):
		int b = 3
		while (b <= 5):
			sim_partition(c.net, a, b)
			b = b + 1
		a = a + 1
	# the minority pair can chase terms as candidates forever but can
	# never assemble 3 votes; the majority side elects
	int k = 0
	while (k < 200):
		cluster_step(c)
		assert1(raft_state(c.nodes[0]) != raft_leader())
		assert1(raft_state(c.nodes[1]) != raft_leader())
		k = k + 1
	int maj_lid = cluster_leader(c)
	assert1(maj_lid >= 3 && maj_lid <= 5)
	cluster_propose(c, maj_lid, c"m")
	k = 0
	while (k < 50):
		cluster_step(c)
		assert1(raft_state(c.nodes[0]) != raft_leader())
		assert1(raft_state(c.nodes[1]) != raft_leader())
		k = k + 1
	# committed on the majority side only
	int i = 2
	while (i < 5):
		assert_equal(1, cl_commit_int(c.nodes[i]))
		i = i + 1
	assert_equal(0, cl_commit_int(c.nodes[0]))
	assert_equal(0, cl_commit_int(c.nodes[1]))
	cluster_heal_all(c)
	cluster_run_steps(c, 300)
	# all five converge on the majority's log; the commit survives the
	# minority's inflated terms
	cluster_assert_logs_identical(c)
	i = 0
	while (i < 5):
		assert_equal(1, raft_log_length(c.nodes[i]))
		assert_equal(1, cl_commit_int(c.nodes[i]))
		i = i + 1
	cluster_free(c)


# ---- client ordering ------------------------------------------------------------

void test_client_command_ordering():
	cluster* c = cluster_new(3, 9009, 0, 0, 0, 900)
	int steps = cluster_run_until_leader(c, 100)
	assert1(steps >= 0)
	int lid = cluster_leader(c)
	list[char*] cmds = list[char*]{c"c1", c"c2", c"c3", c"c4", c"c5"}
	int p = 0
	while (p < cmds.length):
		cluster_propose(c, lid, cmds[p])
		cluster_run_steps(c, 3)
		p = p + 1
	cluster_run_steps(c, 30)
	# applies come out in the same order on every node — and that order
	# is the propose order
	list[char*] first = new list[char*]
	cl_collect_applies(c.nodes[0], first)
	assert_equal(cmds.length, first.length)
	int i = 1
	while (i < 3):
		list[char*] got = new list[char*]
		cl_collect_applies(c.nodes[i], got)
		assert_equal(first.length, got.length)
		int k = 0
		while (k < first.length):
			assert_strings_equal(first[k], got[k])
			k = k + 1
		i = i + 1
	int k2 = 0
	while (k2 < cmds.length):
		assert_strings_equal(cmds[k2], first[k2])
		k2 = k2 + 1
	cluster_free(c)


# ---- commit/apply monotonicity ------------------------------------------------------

void test_no_apply_regression():
	# the replication scenario again, with the safety rails folded into
	# the step loop: per node, commit never decreases and the applied
	# count never exceeds the commit index
	cluster* c = cluster_new(3, 3003, 0, 0, 0, 300)
	int steps = cluster_run_until_leader(c, 100)
	assert1(steps >= 0)
	int lid = cluster_leader(c)
	cluster_propose(c, lid, c"a")
	cluster_propose(c, lid, c"b")
	cluster_propose(c, lid, c"c")
	list[int] prev_commit = list[int]{0, 0, 0}
	list[int] applied = list[int]{0, 0, 0}
	int k = 0
	while (k < 50):
		cluster_step(c)
		int i = 0
		while (i < 3):
			raft* r = c.nodes[i]
			int ci = cl_commit_int(r)
			assert1(ci >= prev_commit[i])
			prev_commit[i] = ci
			list[char*] drained = new list[char*]
			cl_collect_applies(r, drained)
			applied[i] = applied[i] + drained.length
			assert1(applied[i] <= ci)
			i = i + 1
		k = k + 1
	int j = 0
	while (j < 3):
		assert_equal(3, applied[j])
		j = j + 1
	cluster_free(c)


# ---- hardening: no-op on win + pre-vote together --------------------------------

void test_hardened_noop_prevote_cluster():
	# 3 nodes with BOTH opt-in hardening features on: elections go
	# through pre-vote rounds, and every win plants a no-op entry
	cluster* c = cluster_new(3, 12012, 0, 0, 0, 1200)
	int i = 0
	while (i < 3):
		raft_set_noop_on_win(c.nodes[i], 1)
		raft_set_prevote(c.nodes[i], 1)
		i = i + 1
	int steps = cluster_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = cluster_leader(c)
	# the win itself put the no-op in the leader's log
	assert_equal(1, raft_log_length(c.nodes[lid - 1]))
	cluster_propose(c, lid, c"x")
	cluster_run_steps(c, 30)
	i = 0
	while (i < 3):
		raft* r = c.nodes[i]
		assert_equal(2, raft_log_length(r))
		assert_equal(2, cl_commit_int(r))
		raft_entry* head = raft_log_at(r, 1)
		assert_strings_equal(c"", head.command)
		raft_entry* second = raft_log_at(r, 2)
		assert_strings_equal(c"x", second.command)
		# the applier (raft_pop_apply via cl_collect_applies) drains
		# both entries; the no-op surfaces as the empty command and is
		# the consumer's to skip
		list[char*] got = new list[char*]
		cl_collect_applies(r, got)
		assert_equal(2, got.length)
		assert_strings_equal(c"", got[0])
		assert_strings_equal(c"x", got[1])
		i = i + 1
	cluster_assert_logs_identical(c)
	# depose the leader: the survivors pre-vote among themselves (their
	# leader contact goes stale), elect, and the new term's no-op
	# commits with no client proposal
	cluster_partition_from_all(c, lid)
	int k = 0
	int new_lid = 0 - 1
	while (k < 400 && new_lid < 0):
		cluster_step(c)
		int cand = cluster_leader(c)
		if (cand != (0 - 1) && cand != lid):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	cluster_run_steps(c, 30)
	assert_equal(3, raft_log_length(c.nodes[new_lid - 1]))
	assert_equal(3, cl_commit_int(c.nodes[new_lid - 1]))
	cluster_heal_all(c)
	cluster_run_steps(c, 300)
	cluster_assert_no_same_term_leaders(c)
	cluster_assert_logs_identical(c)
	i = 0
	while (i < 3):
		raft* r = c.nodes[i]
		assert_equal(3, raft_log_length(r))
		assert_equal(3, cl_commit_int(r))
		# exactly two no-ops: one per election won
		int noops = 0
		int e = 1
		while (e <= 3):
			raft_entry* entry = raft_log_at(r, e)
			if (strlen(entry.command) == 0):
				noops = noops + 1
			e = e + 1
		assert_equal(2, noops)
		i = i + 1
	cluster_free(c)


# ---- snapshots (§7): compaction, InstallSnapshot catch-up, wal restart -------------

# raft_wal joins late for the restart scenario below; the import is
# appended here to keep this file append-only.
import libs.standard.distributed.raft_wal


int cl_snap_index_int(raft* r):
	u64* v = u64_new()
	raft_snapshot_index(r, v)
	int n = raft_u64_as_int(v)
	u64_free(v)
	return n


# Bytewise blob check against a marker string (blobs are binary).
void cl_assert_blob(char* want, int want_len, char* got, int got_len):
	assert_equal(want_len, got_len)
	int i = 0
	while (i < want_len):
		assert_equal(want[i] & 255, got[i] & 255)
		i = i + 1


void test_snapshot_laggard_catchup():
	# 3 nodes with BOTH hardening features on (the wave-1 recipe:
	# noop_on_win keeps commits flowing without client traffic, and
	# pre-vote keeps the partitioned laggard from inflating terms and
	# deposing the leader on heal). The leader compacts its log below
	# a partitioned follower's next_index; after the heal the laggard
	# must be caught up by an InstallSnapshot plus the suffix entries.
	cluster* c = cluster_new(3, 13013, 0, 0, 0, 1300)
	int i = 0
	while (i < 3):
		raft_set_noop_on_win(c.nodes[i], 1)
		raft_set_prevote(c.nodes[i], 1)
		i = i + 1
	int steps = cluster_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = cluster_leader(c)
	raft* leader = c.nodes[lid - 1]
	# commit six entries: the win no-op plus five proposals
	cluster_propose(c, lid, c"e2")
	cluster_propose(c, lid, c"e3")
	cluster_propose(c, lid, c"e4")
	cluster_propose(c, lid, c"e5")
	cluster_propose(c, lid, c"e6")
	cluster_run_steps(c, 30)
	assert_equal(6, cl_commit_int(leader))
	# partition one follower and commit four more on the majority
	int lag = 1
	if (lag == lid):
		lag = 2
	raft* laggard = c.nodes[lag - 1]
	cluster_partition_from_all(c, lag)
	cluster_propose(c, lid, c"e7")
	cluster_propose(c, lid, c"e8")
	cluster_propose(c, lid, c"e9")
	cluster_propose(c, lid, c"e10")
	cluster_run_steps(c, 30)
	assert_equal(10, cl_commit_int(leader))
	assert_equal(6, cl_commit_int(laggard))
	# the leader applies everything (the driver never applies on its
	# own; this mirrors how scenarios drain applies), then compacts at
	# last_applied = 10 — well past the laggard's next_index
	list[char*] applied = new list[char*]
	cl_collect_applies(leader, applied)
	assert_equal(10, applied.length)
	assert_equal(1, raft_take_snapshot(leader, c"SNAP@10", 7))
	assert_equal(10, cl_snap_index_int(leader))
	assert_equal(0, raft_log_length(leader))
	# two post-snapshot proposals give the laggard a suffix to catch up
	cluster_propose(c, lid, c"e11")
	cluster_propose(c, lid, c"e12")
	cluster_run_steps(c, 30)
	assert_equal(12, cl_commit_int(leader))
	# heal and run: InstallSnapshot, then the suffix appends
	cluster_heal_all(c)
	cluster_run_steps(c, 100)
	cluster_assert_no_same_term_leaders(c)
	# the received snapshot is pending for the state-machine owner,
	# blob and index exactly as the leader took them
	assert_equal(1, raft_has_pending_snapshot(laggard))
	int blen = 0
	u64* bidx = u64_new()
	char* blob = raft_take_pending_snapshot(laggard, &blen, bidx)
	cl_assert_blob(c"SNAP@10", 7, blob, blen)
	assert_equal(10, raft_u64_as_int(bidx))
	free(blob)
	u64_free(bidx)
	# the laggard's log STARTS at the snapshot boundary
	assert_equal(10, cl_snap_index_int(laggard))
	assert_equal(12, raft_last_index(laggard))
	assert_equal(2, raft_log_length(laggard))
	assert_equal(12, cl_commit_int(laggard))
	# with the snapshot installed, the suffix applies flow normally
	list[char*] tail_cmds = new list[char*]
	cl_collect_applies(laggard, tail_cmds)
	assert_equal(2, tail_cmds.length)
	assert_strings_equal(c"e11", tail_cmds[0])
	assert_strings_equal(c"e12", tail_cmds[1])
	# every node agrees on last index and commit
	int j = 0
	while (j < 3):
		assert_equal(12, raft_last_index(c.nodes[j]))
		assert_equal(12, cl_commit_int(c.nodes[j]))
		j = j + 1
	# the never-partitioned follower kept the FULL 12-entry history...
	int other = 1
	while (other == lid || other == lag):
		other = other + 1
	raft* full = c.nodes[other - 1]
	assert_equal(12, raft_log_length(full))
	raft_entry* head = raft_log_at(full, 1)
	assert_strings_equal(c"", head.command)
	raft_entry* second = raft_log_at(full, 2)
	assert_strings_equal(c"e2", second.command)
	# ...and the two never-partitioned nodes' logs match entry by entry
	# on every index both still hold (the leader compacted through 10)
	int k = 11
	while (k <= 12):
		raft_entry* mine = raft_log_at(leader, k)
		raft_entry* theirs = raft_log_at(full, k)
		assert_equal(1, u64_eq(mine.term, theirs.term))
		assert_strings_equal(mine.command, theirs.command)
		raft_entry* lags = raft_log_at(laggard, k)
		assert_equal(1, u64_eq(lags.term, theirs.term))
		assert_strings_equal(lags.command, theirs.command)
		k = k + 1
	cluster_free(c)


# Per-target wal path for the snapshot restart scenario (bin/ is
# gitignored scratch space, mirroring raft_wal_test.w).
char* cl_snap_wal_path():
	char* a = strjoin(c"bin/rsim_snap_t", itoa(__word_size__))
	char* path = strjoin(a, c".log")
	free(a)
	return path


void test_snapshot_restart_from_wal():
	# single node + raft_wal + noop_on_win: commit, snapshot, commit
	# more, crash (free all), recover — the snapshot surfaces through
	# the pending slot BEFORE any apply, then the suffix replays and a
	# re-election recommits everything
	char* path = cl_snap_wal_path()
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	list[int] peers = new list[int]
	raft* r = raft_new(1, peers, 50, 100, 10, 77)
	raft_set_noop_on_win(r, 1)
	raft_start(r, 0)
	list[raft_msg*] out = new list[raft_msg*]
	raft_tick(r, 100, out)
	assert_equal(0, out.length)
	assert_equal(raft_leader(), raft_state(r))
	# the win no-op committed at index 1; three real commands follow
	assert_equal(1, raft_propose(r, c"s1", 2, 100, out))
	assert_equal(1, raft_propose(r, c"s2", 2, 101, out))
	assert_equal(1, raft_propose(r, c"s3", 2, 102, out))
	assert_equal(4, cl_commit_int(r))
	assert_equal(5, raft_wal_sync(rw, r))   # STATE + four APPENDs
	# apply all four and snapshot: base 4, empty log
	list[char*] applied = new list[char*]
	cl_collect_applies(r, applied)
	assert_equal(4, applied.length)
	assert_equal(1, raft_take_snapshot(r, c"WAL@4", 5))
	# the sync rewrites the wal: SNAPSHOT + STATE, nothing else
	assert_equal(2, raft_wal_sync(rw, r))
	assert_equal(2, wal_record_count(rw.wlog))
	# two post-snapshot commits land as ordinary APPENDs
	assert_equal(1, raft_propose(r, c"s5", 2, 103, out))
	assert_equal(1, raft_propose(r, c"s6", 2, 104, out))
	assert_equal(6, cl_commit_int(r))
	assert_equal(2, raft_wal_sync(rw, r))
	assert_equal(4, wal_record_count(rw.wlog))
	# crash: free everything; only the wal file survives
	raft_free(r)
	raft_wal_close(rw)
	# recover
	raft_wal* rw2 = raft_wal_open(path)
	assert1(cast(int, rw2) != 0)
	list[int] peers2 = new list[int]
	raft* r2 = raft_wal_recover(rw2, 1, peers2, 50, 100, 10, 78)
	assert_equal(0, raft_wal_sync(rw2, r2))
	# the snapshot is pending and must be taken before any pop_apply
	assert_equal(1, raft_has_pending_snapshot(r2))
	int blen = 0
	u64* bidx = u64_new()
	char* blob = raft_take_pending_snapshot(r2, &blen, bidx)
	cl_assert_blob(c"WAL@4", 5, blob, blen)
	assert_equal(4, raft_u64_as_int(bidx))
	free(blob)
	u64_free(bidx)
	assert_equal(0, raft_has_pending_snapshot(r2))
	assert_equal(4, cl_snap_index_int(r2))
	assert_equal(2, raft_log_length(r2))
	assert_equal(6, raft_last_index(r2))
	assert_equal(4, cl_commit_int(r2))
	assert_equal(1, cl_term_int(r2))
	# tick to leader again: the term-2 win no-op recommits the suffix
	raft_set_noop_on_win(r2, 1)
	raft_start(r2, 200)
	raft_tick(r2, 300, out)
	assert_equal(0, out.length)
	assert_equal(raft_leader(), raft_state(r2))
	assert_equal(2, cl_term_int(r2))
	assert_equal(7, cl_commit_int(r2))
	# pop_apply yields exactly the post-snapshot entries, then the
	# fresh no-op the re-election planted
	list[char*] again = new list[char*]
	cl_collect_applies(r2, again)
	assert_equal(3, again.length)
	assert_strings_equal(c"s5", again[0])
	assert_strings_equal(c"s6", again[1])
	assert_strings_equal(c"", again[2])
	# log/commit/terms all consistent after the restart
	raft_entry* e5 = raft_log_at(r2, 5)
	assert_strings_equal(c"s5", e5.command)
	assert_equal(1, raft_u64_as_int(e5.term))
	raft_entry* e7 = raft_log_at(r2, 7)
	assert_strings_equal(c"", e7.command)
	assert_equal(2, raft_u64_as_int(e7.term))
	assert_equal(7, raft_last_index(r2))
	assert_equal(3, raft_log_length(r2))
	# the re-election and the no-op still need persisting
	assert_equal(2, raft_wal_sync(rw2, r2))   # STATE + APPEND(no-op)
	assert_equal(0, raft_wal_pending(rw2, r2))
	raft_free(r2)
	raft_wal_close(rw2)
	free(path)
