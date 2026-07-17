# wbuild: x64
import lib.testing
import libs.standard.distributed.raft
import libs.standard.distributed.sim


/*
Cluster membership changes (Ongaro thesis §4.1, single-server changes;
issue #319; raft.w's "Cluster membership changes" header) driven
through the same deterministic sim harness raft_sim_test.w uses
(docs/projects/distributed.md, phase 3). Kept as its own self-
contained driver (mc_* — mirroring cluster_* there) rather than
importing raft_sim_test.w: this tree's convention is that every
*_test.w is a standalone main() via lib.testing (raft_restart_sim_
test.w's independent rcluster driver is the same call), and two
files both defining test_* + main() cannot coexist in one import
graph.

mc_new starts a cluster the usual way (n nodes, full mesh); mc_add_
node appends a NEW raft with a fresh id and an EMPTY peers list — it
learns the cluster's membership, and catches up its log, purely
through the replicated config-change entry the leader proposes via
raft_propose_add_server, exactly as a real fresh node would (no
special-cased bootstrap). Node ids are assigned in increasing order
(1, 2, 3, ...) and never reused within one mcluster.

Every node runs with pre-vote (raft_set_prevote) ON: a removed-but-
not-crashed node keeps ticking and, once its heartbeats stop, would
otherwise time out and disrupt the live leader with ever-higher terms
(§4.2.1 — raft_handle_vote_req does not filter by current membership,
raft.w's header) — its former peers still exist and are still network-
reachable in these sim scenarios (unlike a partition, removal is
purely a config change, not a network split), so this is the one place
that gap is actually reachable in-process. Pre-vote + leader stickiness
is this stack's documented mitigation (raft.w header); it is exercised
for real here, not just asserted in prose.
*/


# ---- u64 conveniences ---------------------------------------------------------

int mc_term_int(raft* r):
	u64* t = u64_new()
	raft_term(r, t)
	int v = raft_u64_as_int(t)
	u64_free(t)
	return v


int mc_commit_int(raft* r):
	u64* ci = u64_new()
	raft_commit_index(r, ci)
	int v = raft_u64_as_int(ci)
	u64_free(ci)
	return v


# ---- cluster driver -------------------------------------------------------------

struct mcluster:
	list[raft*] nodes   # index i holds the raft for node id i + 1
	sim_net* net


list[int] mc_peers_1_to_n(int n, int id):
	list[int] peers = new list[int]
	int p = 1
	while (p <= n):
		if (p != id):
			peers.push(p)
		p = p + 1
	return peers


mcluster* mc_new(int n, int sim_seed, int min_delay, int max_delay, int drop_per_mille, int raft_seed_base):
	mcluster* c = new mcluster()
	c.net = sim_new(sim_seed, min_delay, max_delay, drop_per_mille)
	c.nodes = new list[raft*]
	int id = 1
	while (id <= n):
		raft* r = raft_new(id, mc_peers_1_to_n(n, id), 150, 300, 50, raft_seed_base + id)
		raft_set_prevote(r, 1)
		raft_start(r, sim_now(c.net))
		c.nodes.push(r)
		id = id + 1
	return c


# Appends a brand-new node with an EMPTY peers list — it knows nothing
# until the leader's add-server entry (and whatever replicates after)
# reaches it. Returns the assigned id.
int mc_add_node(mcluster* c, int seed):
	int id = c.nodes.length + 1
	list[int] peers = new list[int]
	raft* r = raft_new(id, peers, 150, 300, 50, seed)
	raft_set_prevote(r, 1)
	raft_start(r, sim_now(c.net))
	c.nodes.push(r)
	return id


void mc_route_out(mcluster* c, list[raft_msg*] out):
	int i = 0
	while (i < out.length):
		raft_msg* m = out[i]
		if (sim_send(c.net, m.from, m.to, cast(char*, m)) == 0):
			raft_msg_free(m)
		i = i + 1
	out.clear()


void mc_drain_dropped(mcluster* c):
	char* d = sim_take_dropped(c.net)
	while (d != 0):
		raft_msg_free(cast(raft_msg*, d))
		d = sim_take_dropped(c.net)


void mc_deliver_due(mcluster* c):
	int from = 0
	int to = 0
	list[raft_msg*] out = new list[raft_msg*]
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg* m = cast(raft_msg*, p)
		raft* dest = c.nodes[to - 1]
		raft_on_msg(dest, m, sim_now(c.net), out)
		raft_msg_free(m)
		mc_route_out(c, out)
		p = sim_take_due(c.net, &from, &to)
	mc_drain_dropped(c)


void mc_step(mcluster* c):
	list[raft_msg*] out = new list[raft_msg*]
	int i = 0
	while (i < c.nodes.length):
		raft_tick(c.nodes[i], sim_now(c.net), out)
		mc_route_out(c, out)
		i = i + 1
	mc_deliver_due(c)
	sim_advance(c.net, 10)


void mc_run_steps(mcluster* c, int k):
	int i = 0
	while (i < k):
		mc_step(c)
		i = i + 1


# Never two leaders in the SAME term (split brain); different-term
# leaders are a legal transient.
void mc_assert_no_same_term_leaders(mcluster* c):
	u64* ti = u64_new()
	u64* tj = u64_new()
	int i = 0
	while (i < c.nodes.length):
		if (raft_state(c.nodes[i]) == raft_leader()):
			int j = i + 1
			while (j < c.nodes.length):
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
int mc_leader(mcluster* c):
	u64* best = u64_new()
	u64* t = u64_new()
	int found = 0
	int dup = 0
	int leader_id = 0 - 1
	int i = 0
	while (i < c.nodes.length):
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


int mc_run_until_leader(mcluster* c, int max_steps):
	int steps = 0
	while (steps < max_steps):
		if (mc_leader(c) != (0 - 1)):
			return steps
		mc_step(c)
		mc_assert_no_same_term_leaders(c)
		steps = steps + 1
	if (mc_leader(c) != (0 - 1)):
		return steps
	return 0 - 1


void mc_partition_from_all(mcluster* c, int id):
	int i = 1
	while (i <= c.nodes.length):
		if (i != id):
			sim_partition(c.net, id, i)
		i = i + 1


void mc_heal_all(mcluster* c):
	int a = 1
	while (a <= c.nodes.length):
		int b = a + 1
		while (b <= c.nodes.length):
			sim_heal(c.net, a, b)
			b = b + 1
		a = a + 1


void mc_propose(mcluster* c, int id, char* command):
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, raft_propose(c.nodes[id - 1], command, strlen(command), sim_now(c.net), out))
	mc_route_out(c, out)


int mc_has_peer(raft* r, int id):
	int i = 0
	while (i < raft_peer_count(r)):
		if (raft_peer_at(r, i) == id):
			return 1
		i = i + 1
	return 0


# Leader-only: propose adding new_id, asserting it is accepted, and
# route the resulting appends.
void mc_add_server(mcluster* c, int leader_id, int new_id):
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, raft_propose_add_server(c.nodes[leader_id - 1], new_id, sim_now(c.net), out))
	mc_route_out(c, out)


void mc_remove_server(mcluster* c, int leader_id, int target_id):
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(1, raft_propose_remove_server(c.nodes[leader_id - 1], target_id, sim_now(c.net), out))
	mc_route_out(c, out)


# Pop every pending apply on r, pushing the borrowed command pointers
# onto into (the log still owns the entries) — mirrors raft_sim_test.w's
# cl_collect_applies.
void mc_collect_applies(raft* r, list[char*] into):
	while (raft_pending_apply(r) == 1):
		raft_entry* e = raft_pop_apply(r)
		into.push(e.command)


void mc_free(mcluster* c):
	sim_advance(c.net, 1000000)
	int from = 0
	int to = 0
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg_free(cast(raft_msg*, p))
		p = sim_take_due(c.net, &from, &to)
	mc_drain_dropped(c)
	int i = 0
	while (i < c.nodes.length):
		raft_free(c.nodes[i])
		i = i + 1
	sim_free(c.net)
	free(c)


# ---- grow -------------------------------------------------------------------------

# 3 -> 4 -> 5: each new node converges (catches up its log purely
# through the replicated add-server entry and ordinary replication —
# no snapshot needed, the log is short) and genuinely participates in
# quorum, proven by then failing an ORIGINAL node and showing the
# cluster still commits: with only the leader and one original peer
# left reachable (2 of 5), majority (3) is unreachable UNLESS the two
# grown members are actually counted and actually replicating.
void test_grow_3_to_5_new_nodes_participate_in_quorum():
	mcluster* c = mc_new(3, 21001, 0, 0, 0, 2100)
	int steps = mc_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = mc_leader(c)

	# grow to 4
	int id4 = mc_add_node(c, 8004)
	assert_equal(4, id4)
	mc_add_server(c, lid, id4)
	mc_run_steps(c, 60)
	assert_equal(lid, mc_leader(c))
	assert_equal(0, raft_config_pending(c.nodes[lid - 1]))
	assert_equal(3, raft_peer_count(c.nodes[lid - 1]))
	assert_equal(1, mc_has_peer(c.nodes[lid - 1], id4))

	# grow to 5
	int id5 = mc_add_node(c, 8005)
	assert_equal(5, id5)
	mc_add_server(c, lid, id5)
	mc_run_steps(c, 60)
	assert_equal(lid, mc_leader(c))
	assert_equal(4, raft_peer_count(c.nodes[lid - 1]))
	assert_equal(1, mc_has_peer(c.nodes[lid - 1], id5))

	# every node (including the two grown ones) converges on the same
	# 2-entry config log (add id4, add id5) before any client traffic
	int i = 0
	while (i < 5):
		raft* r = c.nodes[i]
		assert_equal(2, raft_log_length(r))
		assert_equal(2, mc_commit_int(r))
		i = i + 1

	# fail an ORIGINAL node (not the leader): 4 of 5 remain live, but
	# only the leader + one original peer are old members -- committing
	# needs the two grown nodes to actually count
	int victim = 1
	if (victim == lid):
		victim = 2
	mc_partition_from_all(c, victim)
	mc_propose(c, lid, c"grown-quorum")
	int k = 0
	int committed = 0
	while (k < 200 && committed == 0):
		mc_step(c)
		if (mc_commit_int(c.nodes[lid - 1]) >= 3):
			committed = 1
		k = k + 1
	assert_equal(1, committed)
	# extra settle rounds: the leader reaching commit 3 doesn't mean
	# every follower's own commit_index (advanced via leader_commit on
	# the NEXT heartbeat/append) has caught up yet
	mc_run_steps(c, 30)
	# the two grown nodes and the surviving original peer all catch up
	i = 1
	while (i <= 5):
		if (i != victim):
			raft* r = c.nodes[i - 1]
			assert_equal(3, mc_commit_int(r))
			raft_entry* e = raft_log_at(r, 3)
			assert_strings_equal(c"grown-quorum", e.command)
		i = i + 1
	mc_free(c)


# ---- shrink -------------------------------------------------------------------------

# 5 -> 4: remove a non-leader member; commits keep flowing on the
# smaller config (majority drops from 3 to 3... no: majority of 4 is
# 3, same numeric value as of 5, but the DENOMINATOR shrinks, so the
# removed node's silence can no longer block anything), and the
# removed node is no longer counted (raft_peer_count on every survivor
# drops to 3, the removed id absent).
void test_shrink_5_to_4():
	mcluster* c = mc_new(5, 22002, 0, 0, 0, 2200)
	int steps = mc_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = mc_leader(c)
	int victim = 1
	if (victim == lid):
		victim = 2
	mc_remove_server(c, lid, victim)
	mc_run_steps(c, 40)
	assert_equal(lid, mc_leader(c))
	assert_equal(0, raft_config_pending(c.nodes[lid - 1]))
	assert_equal(3, raft_peer_count(c.nodes[lid - 1]))
	assert_equal(0, mc_has_peer(c.nodes[lid - 1], victim))
	# a normal command still commits with the smaller config
	mc_propose(c, lid, c"post-shrink")
	mc_run_steps(c, 30)
	assert_equal(2, mc_commit_int(c.nodes[lid - 1]))
	int i = 1
	while (i <= 5):
		if (i != victim):
			raft* r = c.nodes[i - 1]
			assert_equal(2, mc_commit_int(r))
			assert_equal(3, raft_peer_count(r))
			assert_equal(0, mc_has_peer(r, victim))
		i = i + 1
	mc_free(c)


# ---- remove the leader ------------------------------------------------------------

# The leader proposes its OWN removal (thesis §4.1 explicitly allows
# this). Once the removal commits, it steps down to follower
# (raft_note_commit_advanced) and the remaining majority elects a
# successor that keeps committing.
void test_remove_the_leader_steps_down_and_successor_elected():
	mcluster* c = mc_new(3, 23003, 0, 0, 0, 2300)
	int steps = mc_run_until_leader(c, 200)
	assert1(steps >= 0)
	int old_lid = mc_leader(c)
	raft* old_leader = c.nodes[old_lid - 1]
	mc_remove_server(c, old_lid, old_lid)
	assert_equal(1, raft_config_pending(old_leader))
	# still leader while the removal is only appended, not committed
	assert_equal(raft_leader(), raft_state(old_leader))
	int k = 0
	while (k < 60 && raft_state(old_leader) == raft_leader()):
		mc_step(c)
		k = k + 1
	assert_equal(raft_follower(), raft_state(old_leader))
	assert_equal(0, raft_config_pending(old_leader))
	# the remaining pair elects a successor and keeps committing
	int new_lid = 0 - 1
	k = 0
	while (k < 300 && new_lid < 0):
		mc_step(c)
		int cand = mc_leader(c)
		if (cand != (0 - 1) && cand != old_lid):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	assert1(new_lid != old_lid)
	assert_equal(0, mc_has_peer(c.nodes[new_lid - 1], old_lid))
	mc_propose(c, new_lid, c"after-removal")
	k = 0
	int committed = 0
	while (k < 200 && committed == 0):
		mc_step(c)
		if (mc_commit_int(c.nodes[new_lid - 1]) >= 2):
			committed = 1
		k = k + 1
	assert_equal(1, committed)
	mc_free(c)


# ---- single-in-flight rule (§4.1) --------------------------------------------------

# At most ONE uncommitted config change may be in flight: a second
# proposal is rejected outright (0, log untouched) until the first
# commits, per raft.w's raft_config_pending guard.
void test_reject_second_inflight_config_change():
	mcluster* c = mc_new(3, 24004, 0, 0, 0, 2400)
	int steps = mc_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = mc_leader(c)
	raft* leader = c.nodes[lid - 1]
	int id4 = mc_add_node(c, 8104)
	mc_add_server(c, lid, id4)
	assert_equal(1, raft_config_pending(leader))
	assert_equal(1, raft_log_length(leader))
	# a second add is rejected outright: nothing appended, still pending
	list[raft_msg*] out = new list[raft_msg*]
	assert_equal(0, raft_propose_add_server(leader, id4 + 1, sim_now(c.net), out))
	assert_equal(0, raft_propose_remove_server(leader, 2, sim_now(c.net), out))
	assert_equal(0, out.length)
	assert_equal(1, raft_log_length(leader))
	assert_equal(1, raft_config_pending(leader))
	# let the first change commit, THEN a second proposal is accepted
	mc_run_steps(c, 40)
	assert_equal(0, raft_config_pending(leader))
	assert_equal(1, raft_propose_add_server(leader, id4 + 1, sim_now(c.net), out))
	mc_route_out(c, out)
	assert_equal(1, raft_config_pending(leader))
	assert_equal(2, raft_log_length(leader))
	mc_free(c)


# ---- uncommitted-config rollback on leader change (the hard one) -------------------

# thesis §4.1: "a server always uses the latest configuration in its
# log, regardless of whether that entry is committed" — cuts both
# ways. The old leader is partitioned away right after proposing an
# add-server entry, so the entry is applied LOCALLY (its own r.peers
# already grew) but never replicates. The connected majority elects a
# new leader and commits a DIFFERENT (normal) entry at that same
# conceptual index. On heal, the old leader's conflicting suffix is
# truncated (raft_handle_append's conflict path) — proving raft_note_
# truncated_to correctly reverts r.peers/raft_config_pending to what
# they were BEFORE the now-discarded proposal, not merely that the log
# bytes converge.
void test_uncommitted_config_rollback_on_leader_change():
	mcluster* c = mc_new(3, 25005, 0, 0, 0, 2500)
	int steps = mc_run_until_leader(c, 200)
	assert1(steps >= 0)
	int old_lid = mc_leader(c)
	raft* old_leader = c.nodes[old_lid - 1]
	assert_equal(2, raft_peer_count(old_leader))

	# the proposed new id must exist as a real (if inert) node in the
	# harness BEFORE the partition is drawn, so the old leader's
	# fan-out to its now-larger r.peers (which includes new_id) has a
	# valid — and properly partitioned-away — destination to address;
	# it never hears from anyone in this scenario either way
	int new_id = mc_add_node(c, 8025)
	mc_partition_from_all(c, old_lid)
	mc_add_server(c, old_lid, new_id)
	# applied locally (apply-on-append) even though it will never
	# replicate anywhere from behind the partition
	assert_equal(1, raft_config_pending(old_leader))
	assert_equal(3, raft_peer_count(old_leader))
	assert_equal(1, mc_has_peer(old_leader, new_id))
	assert_equal(1, raft_log_length(old_leader))
	assert_equal(0, mc_commit_int(old_leader))

	# the connected pair elects a new leader and commits a NORMAL entry
	# at the same conceptual index 1
	int new_lid = 0 - 1
	int k = 0
	while (k < 300 && new_lid < 0):
		mc_step(c)
		int cand = mc_leader(c)
		if (cand != (0 - 1) && cand != old_lid):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	mc_propose(c, new_lid, c"real-entry")
	mc_run_steps(c, 40)
	assert_equal(1, mc_commit_int(c.nodes[new_lid - 1]))

	# heal: the old leader's conflicting config entry gets truncated and
	# replaced by the real committed entry -- rolling its config back.
	# raft_log_length alone cannot detect this: truncating the one bad
	# entry and appending the one good entry both leave the count at 1
	# throughout, so wait on the rollback's own signal instead.
	mc_heal_all(c)
	k = 0
	while (k < 300 && raft_config_pending(old_leader) == 1):
		mc_step(c)
		k = k + 1
	# the discarded add-server entry never survived: back to the
	# original 2-peer config, nothing pending
	assert_equal(0, raft_config_pending(old_leader))
	assert_equal(2, raft_peer_count(old_leader))
	assert_equal(0, mc_has_peer(old_leader, new_id))
	assert_equal(raft_follower(), raft_state(old_leader))
	mc_run_steps(c, 40)
	assert_equal(1, raft_log_length(old_leader))
	raft_entry* e = raft_log_at(old_leader, 1)
	assert_strings_equal(c"real-entry", e.command)
	assert_equal(raft_entry_kind_normal(), e.kind)
	# the whole (still 3-node -- node 4 never actually joined) cluster
	# agrees
	int i = 0
	while (i < 3):
		raft* r = c.nodes[i]
		assert_equal(1, raft_log_length(r))
		assert_equal(1, mc_commit_int(r))
		assert_equal(2, raft_peer_count(r))
		i = i + 1
	mc_free(c)
