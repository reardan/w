/*
Logical clocks for distributed protocols
(docs/projects/distributed.md, phase 1).

Vector clocks are the Dynamo version-tracking primitive: one counter
per node, partial order by pointwise comparison. Counters are ints
with a documented 31-bit limit (2^31 - 1 events per node), per the
plan doc's word-size rule; the wire format is nevertheless 64-bit-
ready via u64 when serialization lands.

vclock_compare is a frozen contract consumed by quorum.w:
  -1  a strictly before b (b descends from a, a != b)
   0  equal
   1  a strictly after b (a descends from b, a != b)
   2  concurrent (neither descends from the other)

Lamport clocks and hybrid logical clocks live here too (see the
sections below).
*/
import lib.lib
import lib.memory
import lib.assert
import libs.standard.distributed.u64


# ---- vector clocks ----------------------------------------------------------

struct vclock:
	map[int, int] counters   # node id -> events observed (31-bit limit)


vclock* vclock_new():
	vclock* v = new vclock()
	v.counters = new map[int, int]
	return v


void vclock_free(vclock* v):
	free(v)


int vclock_get(vclock* v, int node):
	if (node in v.counters):
		return v.counters[node]
	return 0


# Record one local event at node.
void vclock_tick(vclock* v, int node):
	int c = vclock_get(v, node)
	assert1(c >= 0)
	v.counters[node] = c + 1


vclock* vclock_clone(vclock* v):
	vclock* out = vclock_new()
	for int node, int c in v.counters:
		out.counters[node] = c
	return out


# v = pointwise max(v, other): what a node does after reading a
# replica's version before writing its own.
void vclock_merge(vclock* v, vclock* other):
	for int node, int c in other.counters:
		if (c > vclock_get(v, node)):
			v.counters[node] = c


# Frozen contract (see header): -1 before, 0 equal, 1 after,
# 2 concurrent.
int vclock_compare(vclock* a, vclock* b):
	int a_smaller = 0
	int b_smaller = 0
	for int node, int c in a.counters:
		int other = vclock_get(b, node)
		if (c < other):
			a_smaller = 1
		if (c > other):
			b_smaller = 1
	for int node, int c in b.counters:
		if (node in a.counters):
			continue
		# a implicitly has 0 here
		if (c > 0):
			a_smaller = 1
	if (a_smaller && b_smaller):
		return 2
	if (a_smaller):
		return 0 - 1
	if (b_smaller):
		return 1
	return 0


# 1 when a equals b or strictly dominates it — i.e. a already reflects
# everything b has seen (the "obsolete version" test in read repair).
int vclock_descends(vclock* a, vclock* b):
	int r = vclock_compare(a, b)
	if (r == 0 || r == 1):
		return 1
	return 0


# ---- lamport clocks ---------------------------------------------------------

# Scalar logical clock (Lamport 1978): a single counter that every
# local/send event advances and every receive fast-forwards past the
# sender's timestamp. Timestamps are ints with the same documented
# 31-bit limit as vclock counters (2^31 - 1 events on the 32-bit
# target), so behavior is identical on 32- and 64-bit targets.

struct lamport_clock:
	int t   # last timestamp issued or observed (31-bit limit)


lamport_clock* lamport_new():
	lamport_clock* c = new lamport_clock()
	c.t = 0
	return c


void lamport_free(lamport_clock* c):
	free(c)


# Current timestamp without advancing.
int lamport_time(lamport_clock* c):
	return c.t


# Local event or send: advance and return the new timestamp.
int lamport_tick(lamport_clock* c):
	c.t = c.t + 1
	return c.t


# Receive rule: t = max(t, remote) + 1, so the receive is ordered after
# both the local past and the sender's timestamp.
int lamport_observe(lamport_clock* c, int remote):
	assert1(remote >= 0)
	if (remote > c.t):
		c.t = remote
	c.t = c.t + 1
	return c.t


# ---- hybrid logical clocks --------------------------------------------------

# Hybrid logical clock (Kulkarni et al. 2014): timestamps stay close to
# the physical clock but preserve the happened-before order even when
# wall time stalls or steps backwards. State is l — the largest physical
# time seen, in wall milliseconds, at most 48 bits used — and c, a
# logical counter ordering events that share the same l.
#
# Packed timestamps are (l << 16) | c in a u64: 48-bit physical ms in
# the high bits, 16-bit counter in the low bits — exactly the layout
# test_hlc_style_packing in u64_test.w round-trips. If c would pass
# 65535 the counter wraps to 0 and l is bumped by one millisecond
# instead (the saturation bump): the packed timestamp keeps strictly
# increasing at the cost of l running ahead of the wall clock by a
# millisecond — which the next real wall reading almost surely absorbs.

struct hlc:
	u64* l   # last physical time, wall ms (at most 48 bits used)
	int c    # logical counter, 0..65535


hlc* hlc_new():
	hlc* h = new hlc()
	h.l = u64_new()
	h.c = 0
	return h


void hlc_free(hlc* h):
	u64_free(h.l)
	free(h)


# Pack the current state as (l << 16) | c into out without advancing
# anything.
void hlc_last(hlc* h, u64* out):
	u64_copy(out, h.l)
	u64_shl(out, 16)
	u64_add_int(out, h.c)


# Local or send event at physical time wall_ms. Advances the clock and
# writes the new packed timestamp to out.
void hlc_now(hlc* h, u64* wall_ms, u64* out):
	if (u64_cmp(wall_ms, h.l) > 0):
		u64_copy(h.l, wall_ms)
		h.c = 0
	else:
		h.c = h.c + 1
		if (h.c > 65535):
			# saturation bump (see header): borrow one ms so the
			# packed timestamp still strictly increases
			u64_inc(h.l)
			h.c = 0
	hlc_last(h, out)


# Receive rule for a remote packed timestamp. The new l is
# max(l, remote's physical part, wall_ms); the new c restarts at 0
# unless the local and/or remote state ties for that maximum, in which
# case it advances past every tying counter. Writes the new packed
# timestamp to out.
void hlc_observe(hlc* h, u64* wall_ms, u64* remote, u64* out):
	# unpack remote: physical ms in the high 48 bits, counter in the
	# low 16 — which is exactly the w0 limb
	u64* rl = u64_clone(remote)
	u64_shr(rl, 16)
	int rc = remote.w0
	# nl = max(l, rl, wall_ms)
	u64* nl = u64_clone(h.l)
	u64_max(nl, rl)
	u64_max(nl, wall_ms)
	int l_ties = u64_eq(nl, h.l)
	int r_ties = u64_eq(nl, rl)
	int nc = 0
	if (l_ties && r_ties):
		nc = h.c
		if (rc > nc):
			nc = rc
		nc = nc + 1
	else:
		if (l_ties):
			nc = h.c + 1
		else:
			if (r_ties):
				nc = rc + 1
	if (nc > 65535):
		# same saturation bump as hlc_now
		u64_inc(nl)
		nc = 0
	u64_copy(h.l, nl)
	h.c = nc
	u64_free(nl)
	u64_free(rl)
	hlc_last(h, out)
