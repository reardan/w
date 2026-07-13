# wbuild: x64
import lib.testing
import lib.container
import libs.standard.distributed.raft
import libs.standard.distributed.sim
import libs.standard.distributed.prng


/*
Deterministic seed-sweep fuzz gate for raft: the phase-5 hardened
configuration (no-op on win + pre-vote, both enabled on every node)
driven through the sim.w network simulator across many seeds — the
FoundationDB-style payoff of the simulation-first design: hundreds of
distinct schedules, one deterministic binary. Each seed runs a compact
5-node cluster scenario (lossy replication, or partition churn with a
leader-isolation failover and, on even seeds, a log-compaction +
InstallSnapshot twist) with safety invariants checked on every round
and at teardown:

  (a) election safety: at most one leader per term EVER, tracked in a
      map from term to leader id accumulated over the whole run — a
      second, different leader observed at the same term fails the
      seed instantly;
  (b) per-node commit indexes never regress;
  (c) log matching: for every node pair, the entries both still hold
      up to min(commit_a, commit_b) are identical (term and command
      bytes); the range starts above the higher snapshot base, since
      compacted prefixes are gone by design;
  (d) applied-sequence equality: the non-empty commands each node
      popped through raft_pop_apply, in order, are identical across
      nodes. Pragmatic scoping for snapshots: a node that installs an
      InstallSnapshot blob jumps its state machine to the snapshot
      point and never re-applies the compacted prefix, so its applied
      list has a gap by design. Such nodes are excluded from (d) and
      the check requires at least two never-reset nodes — which always
      exist, because a snapshot only covers committed entries, and
      commitment required a majority (three of five, at least two of
      them non-leader) to hold those entries in full logs, keeping
      their next_index above the base and InstallSnapshot away;
  (e) convergence: after healing everything, a generous settle window
      must reach a unique highest-term leader with identical
      last index == commit index on every node.

Every run is a pure function of its seed: the sim's drop/delay
schedule, each raft's election jitter, and the scenario's own
partition choices are all prng.w sequences. Scenario decisions draw
from a SEPARATE prng (prng_new(seed + 7777)) — never from the sim's
internal stream, whose roll order is part of the deterministic
delivery schedule. A red seed therefore replays exactly, on every
target, and every asserts() message names the scenario and seed.

Message ownership mirrors raft_sim_test.w: raft_msg* payloads cross
sim.w as opaque char*; delivered messages are freed after raft_on_msg,
send-dropped ones immediately, partition-dropped ones when the dropped
queue drains, and anything still in flight during teardown.
*/


# ---- sweep configuration ------------------------------------------------------

int sweep_seed_count():
	return 100


int sweep_nodes():
	return 5


# Completed-scenario counter asserted by test_sweep_smoke_report: a
# cheap guard that the seed loops were not accidentally short-circuited.
int sweep_scenarios_run


# ---- per-run state --------------------------------------------------------------

# Driver-side bookkeeping for one node.
struct sweep_track:
	int prev_commit       # (b): the commit index seen last round
	int reset             # 1 once an InstallSnapshot reset the applied history
	list[char*] applied   # non-empty commands popped, in apply order


struct sweep_cluster:
	int n                       # node count; ids 1..n live at nodes[id - 1]
	list[raft*] nodes
	list[sweep_track*] track
	sim_net* net
	char* tag                   # "scenario seed N", the asserts() message
	map[int, int] term_leader   # (a): term -> the one leader id ever seen at it
	u64* scratch                # reused for u64 reads (terms, commits, indexes)
	list[raft_msg*] out         # reused outbound message buffer


# ---- u64 reads ------------------------------------------------------------------

int swc_commit(sweep_cluster* c, raft* r):
	raft_commit_index(r, c.scratch)
	return raft_u64_as_int(c.scratch)


int swc_term(sweep_cluster* c, raft* r):
	raft_term(r, c.scratch)
	return raft_u64_as_int(c.scratch)


# ---- cluster lifecycle ------------------------------------------------------------

# Five nodes on sim_new(seed, 1, 25, 80) — 1..25 ms delays, 8% drop —
# rafts seeded seed * 10 + id with election 150..300 ms, heartbeat
# 50 ms, and BOTH phase-5 hardening features enabled.
sweep_cluster* swc_new(int seed, char* scenario):
	sweep_cluster* c = new sweep_cluster()
	c.n = sweep_nodes()
	c.net = sim_new(seed, 1, 25, 80)
	c.nodes = new list[raft*]
	c.track = new list[sweep_track*]
	c.term_leader = new map[int, int]
	c.scratch = u64_new()
	c.out = new list[raft_msg*]
	char* si = itoa(seed)
	c.tag = strjoin(scenario, si)
	free(si)
	int id = 1
	while (id <= c.n):
		list[int] peers = new list[int]
		int p = 1
		while (p <= c.n):
			if (p != id):
				peers.push(p)
			p = p + 1
		raft* r = raft_new(id, peers, 150, 300, 50, seed * 10 + id)
		list_free[int](peers)   # raft_new copied it
		raft_set_noop_on_win(r, 1)
		raft_set_prevote(r, 1)
		raft_start(r, sim_now(c.net))
		c.nodes.push(r)
		sweep_track* t = new sweep_track()
		t.prev_commit = 0
		t.reset = 0
		t.applied = new list[char*]
		c.track.push(t)
		id = id + 1
	return c


# Put every buffered outbound message on the wire. A message the drop
# roll loses stays ours (sim_send returned 0) and is freed on the spot.
void swc_route_out(sweep_cluster* c):
	int i = 0
	while (i < c.out.length):
		raft_msg* m = c.out[i]
		if (sim_send(c.net, m.from, m.to, cast(char*, m)) == 0):
			raft_msg_free(m)
		i = i + 1
	c.out.clear()


# Free every payload the sim dropped at delivery time (partitions).
void swc_drain_dropped(sweep_cluster* c):
	char* d = sim_take_dropped(c.net)
	while (d != 0):
		raft_msg_free(cast(raft_msg*, d))
		d = sim_take_dropped(c.net)


# Deliver every due packet, routing replies straight back onto the
# wire — a 0-delay reply comes due at the same virtual time and is
# delivered later in this same drain.
void swc_deliver_due(sweep_cluster* c):
	int from = 0
	int to = 0
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg* m = cast(raft_msg*, p)
		raft_on_msg(c.nodes[to - 1], m, sim_now(c.net), c.out)
		raft_msg_free(m)
		swc_route_out(c)
		p = sim_take_due(c.net, &from, &to)
	swc_drain_dropped(c)


# The per-round safety pass, folded into every step (cheap int reads
# only): (b) commit monotonicity, the pending-snapshot-first apply
# discipline, and (a) the one-leader-per-term-ever map.
void swc_check_round(sweep_cluster* c):
	int i = 0
	while (i < c.n):
		raft* r = c.nodes[i]
		sweep_track* t = c.track[i]
		# (b) commit indexes never regress
		int ci = swc_commit(c, r)
		asserts(c.tag, ci >= t.prev_commit)
		t.prev_commit = ci
		# pending snapshot FIRST (raft_pop_apply asserts none is
		# pending), then drain applies; installing marks the node's
		# applied history as reset for check (d)
		if (raft_has_pending_snapshot(r) == 1):
			int blen = 0
			char* blob = raft_take_pending_snapshot(r, &blen, c.scratch)
			free(blob)
			t.reset = 1
		while (raft_pending_apply(r) == 1):
			raft_entry* e = raft_pop_apply(r)
			if (strlen(e.command) > 0):
				t.applied.push(e.command)
		# (a) at most one leader per term, ever
		if (raft_state(r) == raft_leader()):
			int term = swc_term(c, r)
			if ((term in c.term_leader) == 1):
				asserts(c.tag, c.term_leader[term] == i + 1)
			else:
				c.term_leader[term] = i + 1
		i = i + 1


# One 10 ms round — tick every node, deliver everything due, advance
# the clock — with the safety pass appended.
void swc_step(sweep_cluster* c):
	int i = 0
	while (i < c.n):
		raft_tick(c.nodes[i], sim_now(c.net), c.out)
		swc_route_out(c)
		i = i + 1
	swc_deliver_due(c)
	sim_advance(c.net, 10)
	swc_check_round(c)


void swc_run(sweep_cluster* c, int k):
	int i = 0
	while (i < k):
		swc_step(c)
		i = i + 1


# The id of the unique leader at the highest term among leaders, or
# 0 - 1 when no node leads or two leaders share that highest term.
int swc_leader(sweep_cluster* c):
	int found = 0
	int dup = 0
	int best_term = 0
	int leader_id = 0 - 1
	int i = 0
	while (i < c.n):
		raft* r = c.nodes[i]
		if (raft_state(r) == raft_leader()):
			int t = swc_term(c, r)
			if (found == 0):
				found = 1
				best_term = t
				leader_id = i + 1
			else:
				int cmp = 0
				if (t > best_term):
					cmp = 1
				if (t < best_term):
					cmp = 0 - 1
				if (cmp > 0):
					best_term = t
					leader_id = i + 1
					dup = 0
				if (cmp == 0):
					dup = 1
		i = i + 1
	if (found == 1 && dup == 0):
		return leader_id
	return 0 - 1


# Step (with checks) until swc_leader finds one; steps taken, or 0 - 1
# on timeout.
int swc_run_until_leader(sweep_cluster* c, int max_steps):
	int steps = 0
	while (steps < max_steps):
		if (swc_leader(c) != (0 - 1)):
			return steps
		swc_step(c)
		steps = steps + 1
	if (swc_leader(c) != (0 - 1)):
		return steps
	return 0 - 1


# Wait until a unique leader exists (asserting it does) and return it.
int swc_wait_leader(sweep_cluster* c, int max_steps):
	asserts(c.tag, swc_run_until_leader(c, max_steps) >= 0)
	return swc_leader(c)


# Propose command on whoever currently leads, re-looking the leader up
# each round — elections may churn under 8% drop; a round with no
# unique leader (or a refused propose) just steps and retries.
void swc_propose_retry(sweep_cluster* c, char* command, int max_rounds):
	int round = 0
	while (round < max_rounds):
		int lid = swc_leader(c)
		if (lid != (0 - 1)):
			if (raft_propose(c.nodes[lid - 1], command, sim_now(c.net), c.out) == 1):
				swc_route_out(c)
				return
		swc_step(c)
		round = round + 1
	asserts(c.tag, 0)


# Block id off from every other node (both directions per pair).
void swc_partition_from_all(sweep_cluster* c, int id):
	int i = 1
	while (i <= c.n):
		if (i != id):
			sim_partition(c.net, id, i)
		i = i + 1


void swc_heal_all(sweep_cluster* c):
	int a = 1
	while (a <= c.n):
		int b = a + 1
		while (b <= c.n):
			sim_heal(c.net, a, b)
			b = b + 1
		a = a + 1


# (e): a unique highest-term leader exists and every node agrees on
# last index == commit index.
int swc_converged(sweep_cluster* c):
	int lid = swc_leader(c)
	if (lid == (0 - 1)):
		return 0
	raft* lead = c.nodes[lid - 1]
	int li = raft_last_index(lead)
	int ci = swc_commit(c, lead)
	if (ci != li):
		return 0
	int i = 0
	while (i < c.n):
		raft* r = c.nodes[i]
		if (raft_last_index(r) != li):
			return 0
		if (swc_commit(c, r) != ci):
			return 0
		i = i + 1
	return 1


# Step (with checks) inside a generous settle window until converged;
# not converging is a red seed.
void swc_settle(sweep_cluster* c, int max_rounds):
	int round = 0
	while (round < max_rounds):
		if (swc_converged(c) == 1):
			return
		swc_step(c)
		round = round + 1
	asserts(c.tag, swc_converged(c))


# (c): for every node pair, entries up to min(commit, commit) are
# identical — term and command bytes — over the range both still hold
# (above the higher snapshot base; compacted prefixes are gone).
void swc_check_log_matching(sweep_cluster* c):
	int i = 0
	while (i < c.n):
		int j = i + 1
		while (j < c.n):
			raft* a = c.nodes[i]
			raft* b = c.nodes[j]
			int lo = raft_snap_base(a)
			if (raft_snap_base(b) > lo):
				lo = raft_snap_base(b)
			lo = lo + 1
			int hi = swc_commit(c, a)
			int cb = swc_commit(c, b)
			if (cb < hi):
				hi = cb
			int k = lo
			while (k <= hi):
				raft_entry* ea = raft_log_at(a, k)
				raft_entry* eb = raft_log_at(b, k)
				asserts(c.tag, u64_eq(ea.term, eb.term) == 1)
				asserts(c.tag, strcmp(ea.command, eb.command) == 0)
				k = k + 1
			j = j + 1
		i = i + 1


# (d): every node that never installed a snapshot popped the exact
# same non-empty command sequence. Nodes that installed one skipped
# the compacted prefix by design and are excluded (header); at least
# two complete histories must remain to compare.
void swc_check_applied_equal(sweep_cluster* c):
	int ref = 0 - 1
	int clean = 0
	int i = 0
	while (i < c.n):
		sweep_track* t = c.track[i]
		if (t.reset == 0):
			clean = clean + 1
			if (ref < 0):
				ref = i
		i = i + 1
	asserts(c.tag, clean >= 2)
	sweep_track* rt = c.track[ref]
	list[char*] want = rt.applied
	i = 0
	while (i < c.n):
		sweep_track* t = c.track[i]
		if (i != ref && t.reset == 0):
			list[char*] got = t.applied
			asserts(c.tag, want.length == got.length)
			int k = 0
			while (k < want.length):
				asserts(c.tag, strcmp(want[k], got[k]) == 0)
				k = k + 1
		i = i + 1


# Drain the wire (in-flight and partition-dropped payloads are all
# raft_msgs we still own), then free the rafts, the sim and the
# driver-side bookkeeping. sim_free never frees payloads, so the drain
# is what prevents leaks; container storage is released so 200 cluster
# runs stay memory-flat.
void swc_free(sweep_cluster* c):
	sim_advance(c.net, 1000000)
	int from = 0
	int to = 0
	char* p = sim_take_due(c.net, &from, &to)
	while (p != 0):
		raft_msg_free(cast(raft_msg*, p))
		p = sim_take_due(c.net, &from, &to)
	swc_drain_dropped(c)
	int i = 0
	while (i < c.n):
		raft_free(c.nodes[i])
		sweep_track* t = c.track[i]
		list_free[char*](t.applied)
		free(t)
		i = i + 1
	sim_free(c.net)
	list_free[raft*](c.nodes)
	list_free[sweep_track*](c.track)
	list_free[raft_msg*](c.out)
	map_free[int, int](c.term_leader)
	u64_free(c.scratch)
	free(c.tag)
	free(c)


# ---- scenarios ------------------------------------------------------------------

# Scenario 1, lossy_life: elect under 8% drop, land three commands at
# spread-out rounds (re-finding the leader each time), run to
# convergence. A command proposed to a soon-deposed leader may be
# truncated away — legal; the checks assert agreement, not durability
# of unacknowledged proposals.
void sweep_lossy_life(int seed):
	sweep_cluster* c = swc_new(seed, c"lossy_life seed ")
	asserts(c.tag, swc_run_until_leader(c, 1000) >= 0)
	swc_propose_retry(c, c"l1", 400)
	swc_run(c, 12)
	swc_propose_retry(c, c"l2", 400)
	swc_run(c, 12)
	swc_propose_retry(c, c"l3", 400)
	swc_heal_all(c)   # nothing is partitioned; keeps the epilogue uniform
	swc_settle(c, 800)
	swc_check_log_matching(c)
	swc_check_applied_equal(c)
	swc_free(c)
	sweep_scenarios_run = sweep_scenarios_run + 1


# Even-seed churn twist: right after the first heal, the then-leader
# snapshots its applied prefix (the driver keeps last_applied == commit
# by draining applies every round). Whether the rejoining laggard is
# still behind enough to need InstallSnapshot — the leader's backoff
# walking next_index to the base — depends on the schedule; across the
# sweep both orders occur, which is the point. No unique leader within
# the window (rare mid-election heal) skips the twist for this seed.
void swc_snapshot_twist(sweep_cluster* c):
	int round = 0
	while (round < 30):
		int lid = swc_leader(c)
		if (lid != (0 - 1)):
			if (raft_take_snapshot(c.nodes[lid - 1], c"SWEEPSNAP", 9) == 1):
				return
		swc_step(c)
		round = round + 1


# Scenario 2, churn: elect, propose, then two partition cycles from
# the scenario prng — the first isolates the CURRENT leader from all
# four peers (forcing the pre-vote failover path on the majority), the
# second blocks a random non-leader pair — each healed and followed by
# a fresh proposal on the then-leader, with the even-seed snapshot
# twist after the first heal. Final heal + settle, then all checks.
void sweep_churn(int seed):
	sweep_cluster* c = swc_new(seed, c"churn seed ")
	# scenario decisions ONLY; never the sim's internal stream
	prng* sc = prng_new(seed + 7777)
	asserts(c.tag, swc_run_until_leader(c, 1000) >= 0)
	swc_propose_retry(c, c"n1", 400)
	swc_run(c, 10)
	# cycle 1: isolate the current leader from ALL four peers
	int lid = swc_wait_leader(c, 400)
	swc_partition_from_all(c, lid)
	swc_run(c, prng_between(sc, 30, 80))
	swc_heal_all(c)
	if (seed % 2 == 0):
		swc_snapshot_twist(c)
	swc_propose_retry(c, c"n2", 400)
	swc_run(c, 10)
	# cycle 2: a random non-leader pair
	lid = swc_wait_leader(c, 400)
	list[int] others = new list[int]
	int idn = 1
	while (idn <= c.n):
		if (idn != lid):
			others.push(idn)
		idn = idn + 1
	int ia = prng_range(sc, others.length)
	int ib = prng_range(sc, others.length - 1)
	if (ib >= ia):
		ib = ib + 1
	int pa = others[ia]
	int pb = others[ib]
	list_free[int](others)
	sim_partition(c.net, pa, pb)
	swc_run(c, prng_between(sc, 30, 80))
	sim_heal(c.net, pa, pb)
	swc_propose_retry(c, c"n3", 400)
	swc_heal_all(c)
	swc_settle(c, 800)
	swc_check_log_matching(c)
	swc_check_applied_equal(c)
	swc_free(c)
	prng_free(sc)
	sweep_scenarios_run = sweep_scenarios_run + 1


# ---- the sweep --------------------------------------------------------------------

void test_sweep_lossy_life():
	int seed = 1
	while (seed <= sweep_seed_count()):
		sweep_lossy_life(seed)
		seed = seed + 1


void test_sweep_churn():
	int seed = 1
	while (seed <= sweep_seed_count()):
		sweep_churn(seed)
		seed = seed + 1


void test_sweep_smoke_report():
	assert_equal(2 * sweep_seed_count(), sweep_scenarios_run)
