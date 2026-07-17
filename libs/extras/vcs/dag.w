/*
Commit-DAG algorithms over opaque 32-byte ids (docs/projects/version_control.md,
issue #252 wave 1, V1c). Ids are caller-owned 32-byte buffers -- the shape of
a cas.w SHA-256 object id -- but this module does not import cas.w and never
hashes anything itself, so it stands alone with no seed-graph contact.

Node insertion order IS topological order: dag_add_node requires every
parent id to already be present (real history is built that way -- you
cannot construct a child commit before its parents exist), so by
induction the recorded insertion sequence always has every parent before
every child. dag_add_node computes each node's generation number (0 for
a root, else 1 + max(parent generations)) from that same requirement.
dag_topo_order / dag_topo_order_reverse just replay (or reverse) the
recorded sequence -- no separate topological-sort pass (e.g. Kahn's
algorithm) is needed, because the insertion invariant already guarantees
one.

dag_merge_base implements git's generation-bounded "paint" algorithm
(paint_down_to_common in git's commit.c): walk a combined frontier from
both inputs, always expanding the highest-generation entry first (so
common history close to the tips is discovered before older history is
even visited), tag each visited node with which side(s) reached it, and
once a node is reached from both sides mark it a result and flag it
"stale" so the walk correctly excludes that result's own ancestors (a
"best" common ancestor / merge base is a common ancestor that is not
itself an ancestor of another common ancestor). Criss-cross histories
(two merges whose parents cross) legitimately produce more than one best
common ancestor; both the frontier tie-break and the final result order
are by ascending insertion sequence number, so the outcome is fully
deterministic and documented as such.

dag_is_ancestor answers reachability -- is `ancestor` reachable by
walking parent edges from `descendant`, counting a node as its own
ancestor (the same convention `git merge-base --is-ancestor` uses) --
with two prunes: a generation cutoff (every edge strictly decreases
generation, so a node whose generation already sits below the target's
cannot lead to it and is skipped without visiting) and a visited set.
The visited set uses structures/bitset.w: every node already carries a
dense 0..count-1 insertion index (`seq` -- the same field the
merge-base tie-break and topo replay use), so a single bit per node in a
bitset sized to the current node count is a perfect fit, with no hashing
and no per-query bucket allocation. Merge-base's per-node state needs
four independent flag bits at once (which side(s) reached a node, stale,
result), which does not fit a bitset's one-bit-per-index model as
naturally, so that walk instead keeps a plain int[] of flags indexed the
same way.

Ids are keyed for lookup by their lowercase hex encoding: a built-in
map[char*, ...] key is a NUL-terminated C string compared by content
(structures/hash_table.w's cstr key kind), and a raw 32-byte hash can
contain embedded zero bytes that would corrupt a strlen/strcmp-based
comparison -- hex has no embedded NUL and is already the display/on-disk
convention version_control.md settles on for cas.w. dag_hex_key encodes
into a single reused scratch buffer instead of mallocing a fresh one per
lookup (the way libs/standard/crypto/base64.w's hex_encode does): a
lookup's hex string is needed only transiently (the map clones it on
insert, and a read is done with it immediately), and dag_find_node runs
on every hot path (dag_is_ancestor, dag_merge_base) that also mallocs a
bitset and/or a queue buffer per call. Mixing a repeated malloc/free of
that size with the *other* fixed sizes those callers allocate feeds the
allocator's first-fit free list a steady stream of odd-sized split
remainders that never get reused, which was measured to turn a tight
reachability-query loop quadratic; one malloc'd scratch buffer, reused
forever, removes that allocation from the hot path entirely.
*/
import lib.lib
import lib.assert
import structures.bitset


# Every id dag.w accepts or returns is exactly this many bytes.
int DAG_ID_SIZE():
	return 32


struct dag_node:
	char* id              # owned 32-byte buffer
	list[dag_node*] parents
	int generation         # 0 for a root; else 1 + max(parent generations)
	int seq                # 0-based insertion index: dense, stable, and
	                        # equal to this node's position in topo order


struct dag:
	map[char*, dag_node*] by_hex   # hex(id) -> node
	list[dag_node*] by_seq         # index == seq; the recorded insertion/topo order


dag* dag_new():
	dag* d = new dag()
	d.by_hex = new map[char*, dag_node*]
	d.by_seq = new list[dag_node*]
	return d


# Number of nodes currently in the dag.
int dag_count(dag* d):
	return d.by_seq.length


# Byte-for-byte equality of two DAG_ID_SIZE() ids.
int dag_id_equal(char* a, char* b):
	int i = 0
	while (i < DAG_ID_SIZE()):
		if (a[i] != b[i]):
			return 0
		i = i + 1
	return 1


# Lazily-allocated, reused-forever scratch buffer for dag_hex_key: see
# the header comment for why this is not a fresh malloc per call.
char* dag_hex_scratch


# Encodes id as DAG_ID_SIZE() * 2 lowercase hex characters into the
# module's scratch buffer and returns it. The result is a map lookup key
# valid only until the next dag_hex_key call (the map clones it if it is
# used to insert); never free() it and never hold onto it.
char* dag_hex_key(char* id):
	if (dag_hex_scratch == 0):
		dag_hex_scratch = malloc(DAG_ID_SIZE() * 2 + 1)
	char* digits = c"0123456789abcdef"
	int i = 0
	while (i < DAG_ID_SIZE()):
		int b = id[i] & 255
		dag_hex_scratch[i * 2] = digits[(b >> 4) & 15]
		dag_hex_scratch[i * 2 + 1] = digits[b & 15]
		i = i + 1
	dag_hex_scratch[DAG_ID_SIZE() * 2] = 0
	return dag_hex_scratch


dag_node* dag_find_node(dag* d, char* id):
	char* key = dag_hex_key(id)
	dag_node* result = 0
	if (key in d.by_hex):
		result = d.by_hex[key]
	return result


# Whether id names a node already inserted.
int dag_contains(dag* d, char* id):
	return dag_find_node(d, id) != 0


dag_node* dag_require_node(dag* d, char* id):
	dag_node* node = dag_find_node(d, id)
	assert1(node != 0)
	return node


# Inserts a new node for id with the given parent ids (0, 1, or N -- N > 1
# is a merge). Every parent must already be present in the dag (the
# loading-order invariant this whole module leans on: see the header
# comment) and id must not already be present. Returns the node's newly
# computed generation number.
int dag_add_node(dag* d, char* id, list[char*] parent_ids):
	assert1(dag_find_node(d, id) == 0)
	dag_node* node = new dag_node()
	node.id = malloc(DAG_ID_SIZE())
	int i = 0
	while (i < DAG_ID_SIZE()):
		node.id[i] = id[i]
		i = i + 1
	node.parents = new list[dag_node*]
	int max_parent_gen = -1
	for char* pid in parent_ids:
		dag_node* p = dag_require_node(d, pid)
		node.parents.push(p)
		if (p.generation > max_parent_gen):
			max_parent_gen = p.generation
	node.generation = max_parent_gen + 1
	node.seq = d.by_seq.length
	d.by_seq.push(node)
	# Recompute (rather than reuse a value from before the parent loop
	# above): dag_require_node's lookups for the parent ids overwrite the
	# shared scratch buffer, so whatever it held for 'id' itself is stale
	# by now. The map clones this key on insert, so the scratch buffer
	# does not need to outlive this call.
	char* key = dag_hex_key(id)
	d.by_hex[key] = node
	return node.generation


# Generation number of id: 0 for a root, else 1 + max(parent generations).
int dag_generation(dag* d, char* id):
	return dag_require_node(d, id).generation


# Parent ids of id, in the order they were supplied to dag_add_node.
# Pointers are owned by the dag; callers must not free or mutate them.
list[char*] dag_parent_ids(dag* d, char* id):
	dag_node* node = dag_require_node(d, id)
	list[char*] result = new list[char*]
	for dag_node* p in node.parents:
		result.push(p.id)
	return result


# All ids in the order they were inserted -- guaranteed to have every
# parent before its children (see the header comment: this is the
# "loading order").
list[char*] dag_topo_order(dag* d):
	list[char*] result = new list[char*]
	for dag_node* n in d.by_seq:
		result.push(n.id)
	return result


# The reverse: children before parents, newest first -- the order a
# 'log'-style walk wants.
list[char*] dag_topo_order_reverse(dag* d):
	list[char*] result = dag_topo_order(d)
	result.reverse()
	return result


# Reachability: true when 'ancestor' is reachable by walking parent edges
# from 'descendant', counting a node as its own ancestor (git's
# --is-ancestor convention: dag_is_ancestor(d, x, x) is always true).
# Bounded by a generation cutoff: every edge strictly decreases
# generation, so a node whose generation already sits below ancestor's
# cannot lead to it and is pruned without being visited.
#
# The BFS queue is a hand-rolled fixed-capacity array, not a built-in
# list[dag_node*]: the visited bitset guarantees every node is enqueued
# at most once, so a buffer sized to dag_count(d) never needs to grow.
# A plain list would instead grow by repeated realloc and (having no
# built-in 'free' to release its backing buffer) leak a bigger one every
# call; across the many repeated queries a reachability index tends to
# see, that leak pattern fragments the allocator's free list badly
# enough to turn each call's malloc into a slow linear scan. One malloc
# and one free of the same fixed size every call keeps the allocator's
# free-list traffic trivial.
int dag_is_ancestor(dag* d, char* ancestor_id, char* descendant_id):
	dag_node* anc = dag_require_node(d, ancestor_id)
	dag_node* desc = dag_require_node(d, descendant_id)
	if (dag_id_equal(anc.id, desc.id)):
		return 1

	int n = dag_count(d)
	bitset* visited = bitset_new(n)
	bitset_set(visited, desc.seq)
	dag_node** queue = cast(dag_node**, malloc(n * __word_size__))
	int queue_len = 0
	queue[queue_len] = desc
	queue_len = queue_len + 1

	int qi = 0
	int result = 0
	while ((qi < queue_len) && (result == 0)):
		dag_node* cur = queue[qi]
		qi = qi + 1
		int pi = 0
		while ((pi < cur.parents.length) && (result == 0)):
			dag_node* p = cur.parents[pi]
			pi = pi + 1
			if (p.generation >= anc.generation):
				if (dag_id_equal(p.id, anc.id)):
					result = 1
				else if (bitset_get(visited, p.seq) == 0):
					bitset_set(visited, p.seq)
					queue[queue_len] = p
					queue_len = queue_len + 1

	free(cast(void*, queue))
	bitset_free(visited)
	return result


# Merge-base flag bits (git's paint_down_to_common): which side(s) a node
# was reached from, whether it -- or a result already found -- makes it
# ineligible ("stale": an ancestor of an already-found merge base is a
# common ancestor too, but never a *best* one), and whether it has
# already been emitted as a result.
int dag_mb_parent1(): return 1
int dag_mb_parent2(): return 2
int dag_mb_stale(): return 4
int dag_mb_result(): return 8


int dag_mb_seq_cmp(dag_node* a, dag_node* b):
	return a.seq - b.seq


# Index (within frontier) of the entry with the highest generation, ties
# broken by the smallest seq -- both the priority and the tie-break are
# fully determined by insertion order, so the walk order (and hence the
# result order) is reproducible run to run.
int dag_mb_pick_next(list[dag_node*] frontier):
	int best = 0
	int i = 1
	while (i < frontier.length):
		dag_node* cand = frontier[i]
		dag_node* cur = frontier[best]
		if (cand.generation > cur.generation):
			best = i
		else if (cand.generation == cur.generation):
			if (cand.seq < cur.seq):
				best = i
		i = i + 1
	return best


# All best common ancestors of a_id and b_id (git's "merge base"): common
# ancestors that are not themselves an ancestor of another common
# ancestor. Usually exactly one; a criss-cross history (two merges whose
# parents cross) can legitimately produce more than one, in which case
# the result is sorted by ascending insertion sequence number for a
# deterministic order.
list[char*] dag_merge_base(dag* d, char* a_id, char* b_id):
	dag_node* a = dag_require_node(d, a_id)
	dag_node* b = dag_require_node(d, b_id)
	if (dag_id_equal(a.id, b.id)):
		list[char*] self_result = new list[char*]
		self_result.push(a.id)
		return self_result

	int n = dag_count(d)
	int* flags = malloc(n * __word_size__)
	int i = 0
	while (i < n):
		flags[i] = 0
		i = i + 1

	list[dag_node*] frontier = new list[dag_node*]
	flags[a.seq] = flags[a.seq] | dag_mb_parent1()
	frontier.push(a)
	flags[b.seq] = flags[b.seq] | dag_mb_parent2()
	frontier.push(b)

	list[dag_node*] results = new list[dag_node*]
	int both = dag_mb_parent1() | dag_mb_parent2()
	int carry_mask = dag_mb_parent1() | dag_mb_parent2() | dag_mb_stale()

	while (frontier.length > 0):
		int at = dag_mb_pick_next(frontier)
		dag_node* commit = frontier[at]
		frontier.remove(at)

		int cflags = flags[commit.seq] & carry_mask
		if (cflags == both):
			if ((flags[commit.seq] & dag_mb_result()) == 0):
				flags[commit.seq] = flags[commit.seq] | dag_mb_result()
				results.push(commit)
			cflags = cflags | dag_mb_stale()

		for dag_node* p in commit.parents:
			if ((flags[p.seq] & cflags) != cflags):
				flags[p.seq] = flags[p.seq] | cflags
				frontier.push(p)

	free(flags)
	results.sort_by(dag_mb_seq_cmp)
	list[char*] out = new list[char*]
	for dag_node* r in results:
		out.push(r.id)
	return out
