/*
Shared driver for the multi-node raft tests (docs/projects/distributed.md,
phase 3): a cluster of rafts wired through the deterministic network
simulator (sim.w), plus the raft-level cluster checks that the real-TCP
kv_cluster_test.w reuses over its own node list.

Every scenario is a pure function of its seeds — prng.w produces
identical sequences on every target — so each assertion is
deterministic and the x64 twins must reproduce the identical run.

Message ownership across the sim boundary: raft_msg* payloads travel
through sim.w as opaque char* (cast on send, cast back on delivery).
Every message is freed exactly once: delivered -> after raft_on_msg;
send-dropped (sim_send returned 0) -> immediately; partition-dropped ->
when the dropped queue is drained; due for a crashed node -> freed
undelivered (the process it was addressed to is gone); still in flight
at teardown -> during rsim_free's drain.

Node id i lives at nodes[i - 1]; a crashed node's slot holds 0. With
wals attached (rsim_attach_wals), every tick, dispatch and proposal is
followed by raft_wal_sync BEFORE the resulting messages hit the wire,
and rsim_crash / rsim_rebuild model a process dying and recovering from
its wal file.

Two leaders in DIFFERENT terms can transiently coexist (a partitioned
stale leader); that is not split brain. Split brain would be two leaders
in the SAME term, and every rsim_step asserts it never happens.
*/
import lib.lib
import lib.assert
import libs.standard.distributed.raft_wal
import libs.standard.distributed.sim


# ---- raft-level helpers over a node list (0 = crashed) ---------------------------

# Every id in 1..n except id.
list[int] raft_peers_except(int n, int id):
	list[int] peers = new list[int]
	for p in range(1, n + 1):
		if (p != id):
			peers.push(p)
	return peers


# Pop every pending apply on r, pushing the borrowed command pointers
# onto into (the log still owns the entries).
void raft_collect_applies(raft* r, list[char*] into):
	while (raft_pending_apply(r) == 1):
		raft_entry* e = raft_pop_apply(r)
		into.push(e.command)


# Never two live leaders in the SAME term (split brain); different-term
# leaders are a legal transient.
void rafts_assert_no_same_term_leaders(list[raft*] nodes):
	u64* ti = u64_new()
	u64* tj = u64_new()
	int i = 0
	while (i < nodes.length):
		if (nodes[i] != 0 && raft_state(nodes[i]) == raft_leader()):
			int j = i + 1
			while (j < nodes.length):
				if (nodes[j] != 0 && raft_state(nodes[j]) == raft_leader()):
					raft_term(nodes[i], ti)
					raft_term(nodes[j], tj)
					assert_equal(0, u64_eq(ti, tj))
				j = j + 1
		i = i + 1
	u64_free(ti)
	u64_free(tj)


# The id of the unique live leader at the highest term among leaders, or
# 0 - 1 when no node leads or two leaders share that highest term.
int rafts_leader(list[raft*] nodes):
	u64* best = u64_new()
	u64* t = u64_new()
	int found = 0
	int dup = 0
	int leader_id = 0 - 1
	for i in range(nodes.length):
		raft* r = nodes[i]
		if (r != 0 && raft_state(r) == raft_leader()):
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
	u64_free(best)
	u64_free(t)
	if (found == 1 && dup == 0):
		return leader_id
	return 0 - 1


# Every live node's log identical to the first live node's: same length,
# same terms, same commands, entry by entry.
void rafts_assert_logs_identical(list[raft*] nodes):
	int ref = 0
	while (ref < nodes.length && nodes[ref] == 0):
		ref = ref + 1
	assert1(ref < nodes.length)
	raft* first = nodes[ref]
	for i in range(ref + 1, nodes.length):
		raft* other = nodes[i]
		if (other != 0):
			assert_equal(raft_log_length(first), raft_log_length(other))
			int k = 1
			while (k <= raft_log_length(first)):
				raft_entry* mine = raft_log_at(first, k)
				raft_entry* theirs = raft_log_at(other, k)
				assert_equal(1, u64_eq(mine.term, theirs.term))
				assert_strings_equal(mine.command, theirs.command)
				k = k + 1


# ---- the simulated cluster --------------------------------------------------------

# Optional per-round hook (rsim.after_step), called with rsim.user.
type rsim_hook = fn(void*) -> void


struct rsim:
	list[raft*] nodes      # node id lives at nodes[id - 1]; 0 while crashed
	list[raft_wal*] wals   # empty, or node i's persistence adapter
	list[char*] paths      # owned wal paths, parallel to wals
	list[raft_msg*] out    # reused outbound buffer
	sim_net* net
	rsim_hook after_step   # 0, or run after every rsim_step
	void* user


# An empty cluster on a fresh sim; rsim_add_node grows it.
rsim* rsim_empty(int sim_seed, int min_delay, int max_delay, int drop_per_mille):
	rsim* c = new rsim()
	c.net = sim_new(sim_seed, min_delay, max_delay, drop_per_mille)
	c.nodes = new list[raft*]
	c.wals = new list[raft_wal*]
	c.paths = new list[char*]
	c.out = new list[raft_msg*]
	c.after_step = 0
	c.user = 0
	return c


# Appends r as the next id, started at the sim's current time. A node
# joining a live cluster starts with an EMPTY peers list: it learns the
# membership from the leader's replicated add-server entry.
int rsim_add_node(rsim* c, raft* r):
	raft_start(r, sim_now(c.net))
	c.nodes.push(r)
	return c.nodes.length


# n rafts with ids 1..n (peers = every other id), election window
# 150..300 ms, heartbeat 50 ms. Each raft is seeded raft_seed_base + id
# so the nodes' election jitter differs.
rsim* rsim_new(int n, int sim_seed, int min_delay, int max_delay, int drop_per_mille, int raft_seed_base):
	rsim* c = rsim_empty(sim_seed, min_delay, max_delay, drop_per_mille)
	int id = 1
	while (id <= n):
		list[int] peers = raft_peers_except(n, id)
		rsim_add_node(c, raft_new(id, peers, 150, 300, 50, raft_seed_base + id))
		peers.free()   # raft_new copied it
		id = id + 1
	return c


# Enables the hardening features (raft.w header) on every node.
void rsim_harden(rsim* c, int noop_on_win, int prevote):
	int i = 0
	while (i < c.nodes.length):
		raft_set_noop_on_win(c.nodes[i], noop_on_win)
		raft_set_prevote(c.nodes[i], prevote)
		i = i + 1


# Pairs node i with a fresh raft_wal at path_of(i + 1) (files reset so
# reruns start clean); the cluster takes ownership of the paths.
void rsim_attach_wal(rsim* c, int id, char* path):
	create_file(path, 420)
	raft_wal* rw = raft_wal_open(path)
	assert1(cast(int, rw) != 0)
	assert_equal(id - 1, c.wals.length)
	c.wals.push(rw)
	c.paths.push(path)


raft* rsim_node(rsim* c, int id):
	return c.nodes[id - 1]


# Persist node index i (no-op without wals or while it is crashed).
void rsim_sync(rsim* c, int i):
	if (c.wals.length > 0 && c.nodes[i] != 0):
		raft_wal_sync(c.wals[i], c.nodes[i])


# Put every buffered outbound message on the wire. A message the drop
# roll loses stays ours (sim_send returned 0) and is freed on the spot.
void rsim_route_out(rsim* c):
	int i = 0
	while (i < c.out.length):
		raft_msg* m = c.out[i]
		if (sim_send(c.net, m.from, m.to, cast(char*, m)) == 0):
			raft_msg_free(m)
		i = i + 1
	c.out.clear()


# Free every payload the sim dropped at delivery time (partitions).
void rsim_drain_dropped(rsim* c):
	char* d = sim_take_dropped(c.net)
	while (d != 0):
		raft_msg_free(cast(raft_msg*, d))
		d = sim_take_dropped(c.net)


# Deliver every due packet to its destination node, persisting and then
# routing replies straight back onto the wire — a 0-delay reply comes
# due at the same virtual time and is delivered later in this same
# drain. A packet due for a crashed node is freed undelivered.
void rsim_deliver_due(rsim* c):
	int from = 0
	int to = 0
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg* m = cast(raft_msg*, p)
		raft* dest = c.nodes[to - 1]
		if (dest != 0):
			raft_on_msg(dest, m, sim_now(c.net), c.out)
			rsim_sync(c, to - 1)   # persist before replying
			rsim_route_out(c)
		raft_msg_free(m)
		p = sim_take_due(c.net, &from, &to)
	rsim_drain_dropped(c)


# One 10 ms round: tick every live node (persisting, then routing what
# it emits), deliver everything due at the current time, then advance
# the clock — delivery before advance means a 0-delay message sent this
# round arrives this round. The split-brain rail and the after_step
# hook run at the end of every round.
void rsim_step(rsim* c):
	int i = 0
	while (i < c.nodes.length):
		if (c.nodes[i] != 0):
			raft_tick(c.nodes[i], sim_now(c.net), c.out)
			rsim_sync(c, i)
			rsim_route_out(c)
		i = i + 1
	rsim_deliver_due(c)
	sim_advance(c.net, 10)
	rafts_assert_no_same_term_leaders(c.nodes)
	if (c.after_step != 0):
		rsim_hook hook = c.after_step
		hook(c.user)


void rsim_run(rsim* c, int k):
	for i in range(k):
		rsim_step(c)


int rsim_leader(rsim* c):
	return rafts_leader(c.nodes)


# Step until rsim_leader finds one; steps taken, or 0 - 1 on timeout.
int rsim_run_until_leader(rsim* c, int max_steps):
	int steps = 0
	while (steps < max_steps):
		if (rsim_leader(c) != (0 - 1)):
			return steps
		rsim_step(c)
		steps = steps + 1
	if (rsim_leader(c) != (0 - 1)):
		return steps
	return 0 - 1


# Every node alive and its log identical to node 1's.
void rsim_assert_logs_identical(rsim* c):
	int i = 0
	while (i < c.nodes.length):
		asserts(c"node alive", c.nodes[i] != 0)
		i = i + 1
	rafts_assert_logs_identical(c.nodes)


# Persist the proposer and put the appends from an accepted proposal
# (accepted == 1 asserted) on the wire.
void rsim_route_accepted(rsim* c, int id, int accepted):
	assert_equal(1, accepted)
	rsim_sync(c, id - 1)
	rsim_route_out(c)


# Propose on node id (asserting it is alive and accepts, i.e. believes
# it leads), persist, then route.
void rsim_propose(rsim* c, int id, char* command):
	raft* r = c.nodes[id - 1]
	asserts(c"proposer alive", r != 0)
	rsim_route_accepted(c, id, raft_propose(r, command, strlen(command), sim_now(c.net), c.out))


# Leader-only membership changes (raft.w §4.1), asserted accepted.
void rsim_add_server(rsim* c, int leader_id, int new_id):
	rsim_route_accepted(c, leader_id, raft_propose_add_server(c.nodes[leader_id - 1], new_id, sim_now(c.net), c.out))


void rsim_remove_server(rsim* c, int leader_id, int target_id):
	rsim_route_accepted(c, leader_id, raft_propose_remove_server(c.nodes[leader_id - 1], target_id, sim_now(c.net), c.out))


# Block id off from every other node (both directions per pair).
void rsim_partition_from_all(rsim* c, int id):
	int i = 1
	while (i <= c.nodes.length):
		if (i != id):
			sim_partition(c.net, id, i)
		i = i + 1


void rsim_heal_all(rsim* c):
	int a = 1
	while (a <= c.nodes.length):
		int b = a + 1
		while (b <= c.nodes.length):
			sim_heal(c.net, a, b)
			b = b + 1
		a = a + 1


# Crash node id: one last sync (the step loop already synced after the
# last event, so this is usually a no-op), then the process dies — the
# raft is freed and the adapter closed. The wal FILE survives.
void rsim_crash(rsim* c, int id):
	asserts(c"crash a live node", c.nodes[id - 1] != 0)
	rsim_sync(c, id - 1)
	raft_free(c.nodes[id - 1])
	raft_wal_close(c.wals[id - 1])
	c.nodes[id - 1] = 0


# Rebuild node id from its wal: reopen the adapter (replaying the
# shadow), recover a fresh raft from the records, and start it at the
# sim's current time. Recovery replays exactly what was persisted, so
# an immediate sync appends nothing.
void rsim_rebuild(rsim* c, int id, int seed):
	asserts(c"rebuild a crashed node", c.nodes[id - 1] == 0)
	raft_wal* rw = raft_wal_open(c.paths[id - 1])
	assert1(cast(int, rw) != 0)
	list[int] peers = raft_peers_except(c.nodes.length, id)
	raft* r = raft_wal_recover(rw, id, peers, 150, 300, 50, seed)
	peers.free()
	raft_start(r, sim_now(c.net))
	c.wals[id - 1] = rw
	c.nodes[id - 1] = r
	assert_equal(0, raft_wal_sync(rw, r))


# Drain the wire (in-flight and partition-dropped payloads are all
# raft_msgs we still own), then free the live rafts, close the live
# adapters (crashed nodes' were closed at crash time), and release the
# paths, the sim and the containers. sim_free never frees payloads, so
# the drain is what prevents leaks; releasing container storage keeps
# long seed sweeps memory-flat.
void rsim_free(rsim* c):
	sim_advance(c.net, 1000000)
	int from = 0
	int to = 0
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg_free(cast(raft_msg*, p))
		p = sim_take_due(c.net, &from, &to)
	rsim_drain_dropped(c)
	int i = 0
	while (i < c.nodes.length):
		if (c.nodes[i] != 0):
			raft_free(c.nodes[i])
			if (c.wals.length > 0):
				raft_wal_close(c.wals[i])
		i = i + 1
	i = 0
	while (i < c.paths.length):
		free(c.paths[i])
		i = i + 1
	sim_free(c.net)
	c.nodes.free()
	c.wals.free()
	c.paths.free()
	c.out.free()
	free(c)
