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
