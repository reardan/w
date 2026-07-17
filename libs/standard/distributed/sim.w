/*
Deterministic network simulation harness (docs/projects/distributed.md,
phase 3) — the FoundationDB-style substrate that raft's multi-node
tests drive: a virtual clock, a seeded lossy/reordering message queue,
and partitions.

A run is a pure function of (seed, call script) — byte-for-byte
identical on every target, because every random decision comes from
prng.w (identical sequences everywhere) and no real clock or socket is
touched:

  - Virtual clock: sim_now starts at 0 ms and only moves when the
    caller invokes sim_advance.
  - Loss and delay: sim_send consumes prng rolls in a FIXED order —
    one drop roll always, then one delay roll only when the packet
    survives — so the prng stream stays aligned with the call script
    and delivery schedules replay exactly.
  - Delivery order: sim_take_due returns the due packet (deliver_at <=
    now) with the lowest (deliver_at, seq); seq is a monotonic
    assignment counter, so equal-delay packets come out in send order
    and reordering only happens when the delay rolls cause it.
  - Partitions: sim_partition(a, b) blocks the unordered pair in BOTH
    directions. Blocking is evaluated at DELIVERY time, not send time:
    a packet sent during a partition still delivers if the pair heals
    before it comes due (in-flight datagrams survive a heal, as on a
    real network), and a packet sent before the partition drops if the
    pair is blocked when it comes due.

Payload memory: payloads are opaque char* owned by the caller; the
simulator never reads or frees them. sim_send returning 0 (drop roll
lost) leaves ownership with the caller. A packet dropped at delivery
time by a partition parks its payload on an internal queue drained
with sim_take_dropped, which hands ownership back to the caller.
sim_free frees the remaining packet structs but never payloads, so
undelivered or undrained payloads leak unless the caller drains
first — fine for tests.
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.prng


# ---- state ------------------------------------------------------------------

struct sim_packet:
	int seq          # monotonic assignment counter; the reorder tiebreaker
	int from
	int to
	int deliver_at   # virtual ms
	char* payload    # opaque, caller-owned


struct sim_net:
	int now                       # virtual clock, ms since sim_new
	prng* rng
	int next_seq
	list[sim_packet*] in_flight
	int min_delay
	int max_delay
	int drop_per_mille            # 0..1000 sends lost per thousand
	list[int] part_a              # parallel lists: blocked unordered pairs,
	list[int] part_b              # normalized so part_a[i] <= part_b[i]
	list[char*] dropped_payloads  # partition drops awaiting sim_take_dropped


# ---- lifecycle --------------------------------------------------------------

sim_net* sim_new(int seed, int min_delay_ms, int max_delay_ms, int drop_per_mille):
	assert1(min_delay_ms >= 0)
	assert1(min_delay_ms <= max_delay_ms)
	assert1(drop_per_mille >= 0)
	assert1(drop_per_mille <= 1000)
	sim_net* s = new sim_net()
	s.now = 0
	s.rng = prng_new(seed)
	s.next_seq = 0
	s.in_flight = new list[sim_packet*]
	s.min_delay = min_delay_ms
	s.max_delay = max_delay_ms
	s.drop_per_mille = drop_per_mille
	s.part_a = new list[int]
	s.part_b = new list[int]
	s.dropped_payloads = new list[char*]
	return s


# Frees the prng, the packet structs still in flight, and the sim
# itself — never a payload (header): drain deliveries and
# sim_take_dropped first when payload leaks matter.
void sim_free(sim_net* s):
	int i = 0
	while (i < s.in_flight.length):
		free(s.in_flight[i])
		i = i + 1
	prng_free(s.rng)
	free(s)


# ---- virtual clock ----------------------------------------------------------

int sim_now(sim_net* s):
	return s.now


void sim_advance(sim_net* s, int dt):
	assert1(dt >= 0)
	s.now = s.now + dt


# ---- partitions -------------------------------------------------------------

# Index of the unordered pair (a, b) in the partition lists, or 0 - 1
# when the pair is not blocked.
int sim_pair_index(sim_net* s, int a, int b):
	int lo = a
	int hi = b
	if (lo > hi):
		lo = b
		hi = a
	int i = 0
	while (i < s.part_a.length):
		if (s.part_a[i] == lo && s.part_b[i] == hi):
			return i
		i = i + 1
	return 0 - 1


# 1 when the unordered pair (a, b) is currently blocked.
int sim_partitioned(sim_net* s, int a, int b):
	if (sim_pair_index(s, a, b) >= 0):
		return 1
	return 0


# Block the unordered pair (a, b) in both directions. Idempotent.
void sim_partition(sim_net* s, int a, int b):
	if (sim_pair_index(s, a, b) >= 0):
		return
	int lo = a
	int hi = b
	if (lo > hi):
		lo = b
		hi = a
	s.part_a.push(lo)
	s.part_b.push(hi)


# Unblock the pair; harmless when it was never blocked. Packets sent
# during the partition that come due after the heal DO deliver —
# blocking is evaluated at delivery time (header).
void sim_heal(sim_net* s, int a, int b):
	int idx = sim_pair_index(s, a, b)
	if (idx < 0):
		return
	s.part_a.remove(idx)
	s.part_b.remove(idx)


# ---- send -------------------------------------------------------------------

# Queue a packet from -> to. Rolls the prng in the fixed order the
# header freezes: the drop roll always happens, the delay roll only
# when the packet survives. Returns 1 when queued with deliver_at =
# now + a delay in [min_delay, max_delay]; 0 when the drop roll lost
# the packet, in which case the caller keeps payload ownership.
int sim_send(sim_net* s, int from, int to, char* payload):
	if (prng_range(s.rng, 1000) < s.drop_per_mille):
		return 0
	sim_packet* p = new sim_packet()
	p.seq = s.next_seq
	s.next_seq = s.next_seq + 1
	p.from = from
	p.to = to
	p.deliver_at = s.now + prng_between(s.rng, s.min_delay, s.max_delay)
	p.payload = payload
	s.in_flight.push(p)
	return 1


# Packets queued and not yet delivered or partition-dropped.
int sim_pending(sim_net* s):
	return s.in_flight.length


# ---- delivery ---------------------------------------------------------------

# Index of the due packet (deliver_at <= now) with the lowest
# (deliver_at, seq), or 0 - 1 when nothing is due.
int sim_find_due(sim_net* s):
	int best = 0 - 1
	int i = 0
	while (i < s.in_flight.length):
		sim_packet* p = s.in_flight[i]
		if (p.deliver_at <= s.now):
			if (best < 0):
				best = i
			else:
				sim_packet* q = s.in_flight[best]
				if (p.deliver_at < q.deliver_at || (p.deliver_at == q.deliver_at && p.seq < q.seq)):
					best = i
		i = i + 1
	return best


# Deliver the next due packet: lowest (deliver_at, seq) among packets
# with deliver_at <= now. A due packet whose (from, to) pair is
# currently partitioned is dropped instead — its struct is freed, its
# payload parked for sim_take_dropped — and the scan continues.
# Returns the payload and fills from_out/to_out on delivery; returns 0
# with the outputs untouched when nothing deliverable is due.
char* sim_take_due(sim_net* s, int* from_out, int* to_out):
	int idx = sim_find_due(s)
	while (idx >= 0):
		sim_packet* p = s.in_flight[idx]
		s.in_flight.remove(idx)
		if (sim_partitioned(s, p.from, p.to) == 0):
			from_out[0] = p.from
			to_out[0] = p.to
			char* payload = p.payload
			free(p)
			return payload
		s.dropped_payloads.push(p.payload)
		free(p)
		idx = sim_find_due(s)
	return 0


# Payloads dropped at delivery time by a partition, not yet drained.
int sim_dropped_count(sim_net* s):
	return s.dropped_payloads.length


# Oldest partition-dropped payload (FIFO), transferring ownership back
# to the caller; 0 when the queue is empty.
char* sim_take_dropped(sim_net* s):
	if (s.dropped_payloads.length == 0):
		return 0
	char* payload = s.dropped_payloads[0]
	s.dropped_payloads.remove(0)
	return payload
