/*
Consistent hashing with virtual nodes (docs/projects/distributed.md) —
the Dynamo §4.2-4.3 / Memcache-routing partitioning primitive.

Each member node contributes vnodes_per_node points on a circular hash
space; a key is owned by the node of the first ring point clockwise
from (>=) the key's point, wrapping to the smallest point. Virtual
nodes smooth the load: adding or removing one node only moves the keys
adjacent to that node's points.

Hash points are NON-NEGATIVE 31-bit ints, so plain < is a correct
total order on every target. A masked 32-bit word can be stored
negative on the x86 target (lib/sha256.w header), which would corrupt
the ring order there — masking to 31 bits avoids that entirely.

Point derivation is frozen so owners are deterministic across targets
and runs:
  vnode point:  sha256("<node_id>#<vnode_index>"), vnode index in
                decimal, first 4 digest bytes big-endian, masked to
                31 bits
  key point:    sha256(key), same truncation

On a point collision with an existing ring entry the new vnode is
skipped (astronomically unlikely with sha256: 96 vnodes over a 2^31
space collide with probability ~2e-6, and correctness only loses one
virtual node, never a key).

Node id memory: the ring stores the caller's char* pointers and never
copies or frees them; the caller keeps them alive for the life of the
ring (and of any recorded lookup results).
*/
import lib.lib
import lib.memory
import lib.assert
import lib.sha256


struct hash_ring:
	int vnodes_per_node
	list[int] points     # sorted, distinct, non-negative 31-bit hash points
	list[char*] owners   # parallel to points: owning node id per point
	list[char*] nodes    # member node ids, insertion order


# 0x7fffffff built at runtime — a hex literal with bit 31 set would
# sign-extend on every target.
int ring_mask31():
	int q = 1 << 30
	return (q - 1) + q


# sha256 the len-prefixed string, take the first 4 digest bytes
# big-endian, mask to 31 bits. sha256_be32 may return a negative int on
# the x86 target when digest bit 31 is set; the AND keeps only the low
# 31 bits, so the result is the same non-negative int on every target.
int ring_hash_point(char* s):
	char* digest = malloc(32)
	sha256(s, strlen(s), digest)
	int p = sha256_be32(digest) & ring_mask31()
	free(digest)
	return p


# Point of a key on the ring.
int ring_key_point(char* key):
	return ring_hash_point(key)


# Point of virtual node vnode of node_id: hash of "<node_id>#<vnode>".
int ring_vnode_point(char* node_id, int vnode):
	assert1(vnode >= 0)
	char* num = itoa(vnode)
	char* prefix = strjoin(node_id, c"#")
	char* label = strjoin(prefix, num)
	int p = ring_hash_point(label)
	free(label)
	free(prefix)
	free(num)
	return p


hash_ring* ring_new(int vnodes_per_node):
	assert1(vnodes_per_node >= 1)
	hash_ring* r = new hash_ring()
	r.vnodes_per_node = vnodes_per_node
	r.points = new list[int]
	r.owners = new list[char*]
	r.nodes = new list[char*]
	return r


# Frees the ring itself; the built-in containers follow the repo
# convention for struct-held containers (clock.w vclock_free) and the
# node id strings stay with the caller.
void ring_free(hash_ring* r):
	free(r)


int ring_node_count(hash_ring* r):
	return r.nodes.length


int ring_has_node(hash_ring* r, char* node_id):
	int i = 0
	while (i < r.nodes.length):
		if (strcmp(r.nodes[i], node_id) == 0):
			return 1
		i = i + 1
	return 0


# Index of the first ring entry with point >= p; r.points.length when
# every point is < p (the caller wraps to index 0).
int ring_find_index(hash_ring* r, int p):
	int lo = 0
	int hi = r.points.length
	while (lo < hi):
		int mid = (lo + hi) / 2
		if (r.points[mid] < p):
			lo = mid + 1
		else:
			hi = mid
	return lo


# 1 = added, 0 = node_id already a member (ring unchanged).
int ring_add_node(hash_ring* r, char* node_id):
	if (ring_has_node(r, node_id)):
		return 0
	r.nodes.push(node_id)
	int v = 0
	while (v < r.vnodes_per_node):
		int p = ring_vnode_point(node_id, v)
		int idx = ring_find_index(r, p)
		if (idx < r.points.length && r.points[idx] == p):
			# collision with an existing point: skip this vnode
			# (astronomically unlikely, see header)
			v = v + 1
			continue
		r.points.insert(idx, p)
		r.owners.insert(idx, node_id)
		v = v + 1
	return 1


# 1 = removed, 0 = node_id was not a member. Every other node's points
# are untouched, so only keys owned by node_id change owner.
int ring_remove_node(hash_ring* r, char* node_id):
	int found = 0
	int i = 0
	while (i < r.nodes.length):
		if (strcmp(r.nodes[i], node_id) == 0):
			r.nodes.remove(i)
			found = 1
			break
		i = i + 1
	if (found == 0):
		return 0
	i = r.points.length - 1
	while (i >= 0):
		if (strcmp(r.owners[i], node_id) == 0):
			r.points.remove(i)
			r.owners.remove(i)
		i = i - 1
	return 1


# Owning node id for key: the node of the first ring point >= the
# key's point, wrapping to the smallest point. 0 when the ring is
# empty.
char* ring_lookup(hash_ring* r, char* key):
	if (r.points.length == 0):
		return 0
	int idx = ring_find_index(r, ring_key_point(key))
	if (idx >= r.points.length):
		idx = 0
	return r.owners[idx]


# Dynamo preference list: walk clockwise from the key's successor
# point, collecting up to n DISTINCT node ids into out (out must hold
# at least n pointers). Returns the count (min of n and the member
# count); out[0] is ring_lookup's owner. 0 when the ring is empty.
int ring_successors(hash_ring* r, char* key, int n, char** out):
	assert1(n >= 0)
	if (r.points.length == 0 || n == 0):
		return 0
	int idx = ring_find_index(r, ring_key_point(key))
	if (idx >= r.points.length):
		idx = 0
	int count = 0
	int steps = 0
	while (steps < r.points.length && count < n):
		char* owner = r.owners[idx]
		int seen = 0
		int j = 0
		while (j < count):
			if (strcmp(out[j], owner) == 0):
				seen = 1
				break
			j = j + 1
		if (seen == 0):
			out[count] = owner
			count = count + 1
		idx = idx + 1
		if (idx >= r.points.length):
			idx = 0
		steps = steps + 1
	return count
