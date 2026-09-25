# wbuild: x64
import lib.testing
import libs.standard.distributed.raft_sim_harness


/*
Cluster membership changes (Ongaro thesis §4.1, single-server changes;
issue #319; raft.w's "Cluster membership changes" header) driven
through the shared deterministic sim harness (raft_sim_harness.w,
docs/projects/distributed.md phase 3).

mc_new starts a cluster the usual way (n nodes, full mesh); mc_add_
node appends a NEW raft with a fresh id and an EMPTY peers list — it
learns the cluster's membership, and catches up its log, purely
through the replicated config-change entry the leader proposes via
raft_propose_add_server, exactly as a real fresh node would (no
special-cased bootstrap). Node ids are assigned in increasing order
(1, 2, 3, ...) and never reused within one cluster.

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


# ---- cluster driver (raft_sim_harness.w, every node with pre-vote) ---------------

rsim* mc_new(int n, int sim_seed, int min_delay, int max_delay, int drop_per_mille, int raft_seed_base):
	rsim* c = rsim_new(n, sim_seed, min_delay, max_delay, drop_per_mille, raft_seed_base)
	rsim_harden(c, 0, 1)
	return c


# Appends a brand-new node with an EMPTY peers list — it knows nothing
# until the leader's add-server entry (and whatever replicates after)
# reaches it. Returns the assigned id.
int mc_add_node(rsim* c, int seed):
	list[int] peers = new list[int]
	raft* r = raft_new(c.nodes.length + 1, peers, 150, 300, 50, seed)
	peers.free()
	raft_set_prevote(r, 1)
	return rsim_add_node(c, r)


int mc_has_peer(raft* r, int id):
	int i = 0
	while (i < raft_peer_count(r)):
		if (raft_peer_at(r, i) == id):
			return 1
		i = i + 1
	return 0


# ---- grow -------------------------------------------------------------------------

# 3 -> 4 -> 5: each new node converges (catches up its log purely
# through the replicated add-server entry and ordinary replication —
# no snapshot needed, the log is short) and genuinely participates in
# quorum, proven by then failing an ORIGINAL node and showing the
# cluster still commits: with only the leader and one original peer
# left reachable (2 of 5), majority (3) is unreachable UNLESS the two
# grown members are actually counted and actually replicating.
void test_grow_3_to_5_new_nodes_participate_in_quorum():
	rsim* c = mc_new(3, 21001, 0, 0, 0, 2100)
	int steps = rsim_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = rsim_leader(c)

	# grow to 4
	int id4 = mc_add_node(c, 8004)
	assert_equal(4, id4)
	rsim_add_server(c, lid, id4)
	rsim_run(c, 60)
	assert_equal(lid, rsim_leader(c))
	assert_equal(0, raft_config_pending(c.nodes[lid - 1]))
	assert_equal(3, raft_peer_count(c.nodes[lid - 1]))
	assert_equal(1, mc_has_peer(c.nodes[lid - 1], id4))

	# grow to 5
	int id5 = mc_add_node(c, 8005)
	assert_equal(5, id5)
	rsim_add_server(c, lid, id5)
	rsim_run(c, 60)
	assert_equal(lid, rsim_leader(c))
	assert_equal(4, raft_peer_count(c.nodes[lid - 1]))
	assert_equal(1, mc_has_peer(c.nodes[lid - 1], id5))

	# every node (including the two grown ones) converges on the same
	# 2-entry config log (add id4, add id5) before any client traffic
	int i = 0
	while (i < 5):
		raft* r = c.nodes[i]
		assert_equal(2, raft_log_length(r))
		assert_equal(2, raft_commit_int(r))
		i = i + 1

	# fail an ORIGINAL node (not the leader): 4 of 5 remain live, but
	# only the leader + one original peer are old members -- committing
	# needs the two grown nodes to actually count
	int victim = 1
	if (victim == lid):
		victim = 2
	rsim_partition_from_all(c, victim)
	rsim_propose(c, lid, c"grown-quorum")
	int k = 0
	int committed = 0
	while (k < 200 && committed == 0):
		rsim_step(c)
		if (raft_commit_int(c.nodes[lid - 1]) >= 3):
			committed = 1
		k = k + 1
	assert_equal(1, committed)
	# extra settle rounds: the leader reaching commit 3 doesn't mean
	# every follower's own commit_index (advanced via leader_commit on
	# the NEXT heartbeat/append) has caught up yet
	rsim_run(c, 30)
	# the two grown nodes and the surviving original peer all catch up
	i = 1
	while (i <= 5):
		if (i != victim):
			raft* r = c.nodes[i - 1]
			assert_equal(3, raft_commit_int(r))
			raft_entry* e = raft_log_at(r, 3)
			assert_strings_equal(c"grown-quorum", e.command)
		i = i + 1
	rsim_free(c)


# ---- shrink -------------------------------------------------------------------------

# 5 -> 4: remove a non-leader member; commits keep flowing on the
# smaller config (majority drops from 3 to 3... no: majority of 4 is
# 3, same numeric value as of 5, but the DENOMINATOR shrinks, so the
# removed node's silence can no longer block anything), and the
# removed node is no longer counted (raft_peer_count on every survivor
# drops to 3, the removed id absent).
void test_shrink_5_to_4():
	rsim* c = mc_new(5, 22002, 0, 0, 0, 2200)
	int steps = rsim_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = rsim_leader(c)
	int victim = 1
	if (victim == lid):
		victim = 2
	rsim_remove_server(c, lid, victim)
	rsim_run(c, 40)
	assert_equal(lid, rsim_leader(c))
	assert_equal(0, raft_config_pending(c.nodes[lid - 1]))
	assert_equal(3, raft_peer_count(c.nodes[lid - 1]))
	assert_equal(0, mc_has_peer(c.nodes[lid - 1], victim))
	# a normal command still commits with the smaller config
	rsim_propose(c, lid, c"post-shrink")
	rsim_run(c, 30)
	assert_equal(2, raft_commit_int(c.nodes[lid - 1]))
	int i = 1
	while (i <= 5):
		if (i != victim):
			raft* r = c.nodes[i - 1]
			assert_equal(2, raft_commit_int(r))
			assert_equal(3, raft_peer_count(r))
			assert_equal(0, mc_has_peer(r, victim))
		i = i + 1
	rsim_free(c)


# ---- remove the leader ------------------------------------------------------------

# The leader proposes its OWN removal (thesis §4.1 explicitly allows
# this). Once the removal commits, it steps down to follower
# (raft_note_commit_advanced) and the remaining majority elects a
# successor that keeps committing.
void test_remove_the_leader_steps_down_and_successor_elected():
	rsim* c = mc_new(3, 23003, 0, 0, 0, 2300)
	int steps = rsim_run_until_leader(c, 200)
	assert1(steps >= 0)
	int old_lid = rsim_leader(c)
	raft* old_leader = c.nodes[old_lid - 1]
	rsim_remove_server(c, old_lid, old_lid)
	assert_equal(1, raft_config_pending(old_leader))
	# still leader while the removal is only appended, not committed
	assert_equal(raft_leader(), raft_state(old_leader))
	int k = 0
	while (k < 60 && raft_state(old_leader) == raft_leader()):
		rsim_step(c)
		k = k + 1
	assert_equal(raft_follower(), raft_state(old_leader))
	assert_equal(0, raft_config_pending(old_leader))
	# the remaining pair elects a successor and keeps committing
	int new_lid = 0 - 1
	k = 0
	while (k < 300 && new_lid < 0):
		rsim_step(c)
		int cand = rsim_leader(c)
		if (cand != (0 - 1) && cand != old_lid):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	assert1(new_lid != old_lid)
	assert_equal(0, mc_has_peer(c.nodes[new_lid - 1], old_lid))
	rsim_propose(c, new_lid, c"after-removal")
	k = 0
	int committed = 0
	while (k < 200 && committed == 0):
		rsim_step(c)
		if (raft_commit_int(c.nodes[new_lid - 1]) >= 2):
			committed = 1
		k = k + 1
	assert_equal(1, committed)
	rsim_free(c)


# ---- single-in-flight rule (§4.1) --------------------------------------------------

# At most ONE uncommitted config change may be in flight: a second
# proposal is rejected outright (0, log untouched) until the first
# commits, per raft.w's raft_config_pending guard.
void test_reject_second_inflight_config_change():
	rsim* c = mc_new(3, 24004, 0, 0, 0, 2400)
	int steps = rsim_run_until_leader(c, 200)
	assert1(steps >= 0)
	int lid = rsim_leader(c)
	raft* leader = c.nodes[lid - 1]
	int id4 = mc_add_node(c, 8104)
	rsim_add_server(c, lid, id4)
	assert_equal(1, raft_config_pending(leader))
	assert_equal(1, raft_log_length(leader))
	# a second add is rejected outright: nothing appended, still pending
	assert_equal(0, raft_propose_add_server(leader, id4 + 1, sim_now(c.net), c.out))
	assert_equal(0, raft_propose_remove_server(leader, 2, sim_now(c.net), c.out))
	assert_equal(0, c.out.length)
	assert_equal(1, raft_log_length(leader))
	assert_equal(1, raft_config_pending(leader))
	# let the first change commit, THEN a second proposal is accepted
	rsim_run(c, 40)
	assert_equal(0, raft_config_pending(leader))
	rsim_route_accepted(c, lid, raft_propose_add_server(leader, id4 + 1, sim_now(c.net), c.out))
	assert_equal(1, raft_config_pending(leader))
	assert_equal(2, raft_log_length(leader))
	rsim_free(c)


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
	rsim* c = mc_new(3, 25005, 0, 0, 0, 2500)
	int steps = rsim_run_until_leader(c, 200)
	assert1(steps >= 0)
	int old_lid = rsim_leader(c)
	raft* old_leader = c.nodes[old_lid - 1]
	assert_equal(2, raft_peer_count(old_leader))

	# the proposed new id must exist as a real (if inert) node in the
	# harness BEFORE the partition is drawn, so the old leader's
	# fan-out to its now-larger r.peers (which includes new_id) has a
	# valid — and properly partitioned-away — destination to address;
	# it never hears from anyone in this scenario either way
	int new_id = mc_add_node(c, 8025)
	rsim_partition_from_all(c, old_lid)
	rsim_add_server(c, old_lid, new_id)
	# applied locally (apply-on-append) even though it will never
	# replicate anywhere from behind the partition
	assert_equal(1, raft_config_pending(old_leader))
	assert_equal(3, raft_peer_count(old_leader))
	assert_equal(1, mc_has_peer(old_leader, new_id))
	assert_equal(1, raft_log_length(old_leader))
	assert_equal(0, raft_commit_int(old_leader))

	# the connected pair elects a new leader and commits a NORMAL entry
	# at the same conceptual index 1
	int new_lid = 0 - 1
	int k = 0
	while (k < 300 && new_lid < 0):
		rsim_step(c)
		int cand = rsim_leader(c)
		if (cand != (0 - 1) && cand != old_lid):
			new_lid = cand
		k = k + 1
	assert1(new_lid >= 1)
	rsim_propose(c, new_lid, c"real-entry")
	rsim_run(c, 40)
	assert_equal(1, raft_commit_int(c.nodes[new_lid - 1]))

	# heal: the old leader's conflicting config entry gets truncated and
	# replaced by the real committed entry -- rolling its config back.
	# raft_log_length alone cannot detect this: truncating the one bad
	# entry and appending the one good entry both leave the count at 1
	# throughout, so wait on the rollback's own signal instead.
	rsim_heal_all(c)
	k = 0
	while (k < 300 && raft_config_pending(old_leader) == 1):
		rsim_step(c)
		k = k + 1
	# the discarded add-server entry never survived: back to the
	# original 2-peer config, nothing pending
	assert_equal(0, raft_config_pending(old_leader))
	assert_equal(2, raft_peer_count(old_leader))
	assert_equal(0, mc_has_peer(old_leader, new_id))
	assert_equal(raft_follower(), raft_state(old_leader))
	rsim_run(c, 40)
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
		assert_equal(1, raft_commit_int(r))
		assert_equal(2, raft_peer_count(r))
		i = i + 1
	rsim_free(c)
