# wbuild: x64
/*
Tests for libs/extras/vcs/dag.w (issue #252 wave 1, V1c): linear chains,
diamond merges, criss-cross histories, generation numbers, reachability,
topo-order validity, and a randomized few-hundred-node DAG cross-checked
against an independent brute-force reference.

Ids are synthesized by vdt_make_id(n): a 32-byte buffer holding n as a
little-endian 32-bit prefix, zero-padded. That is not how real ids look
(dag.w never hashes anything -- it takes ids exactly as given) but it is
trivially unique across the small integers these tests use, which is all
dag.w's contract requires.
*/
import lib.testing
import libs.extras.vcs.dag
import structures.bitset
import tests.asm_fuzz_prng


char* vdt_make_id(int n):
	char* id = malloc(DAG_ID_SIZE())
	int i = 0
	while (i < DAG_ID_SIZE()):
		id[i] = 0
		i = i + 1
	id[0] = n & 255
	id[1] = (n >> 8) & 255
	id[2] = (n >> 16) & 255
	id[3] = (n >> 24) & 255
	return id


list[char*] vdt_ids(char* a):
	list[char*] result = new list[char*]
	result.push(a)
	return result


list[char*] vdt_ids2(char* a, char* b):
	list[char*] result = new list[char*]
	result.push(a)
	result.push(b)
	return result


void vdt_assert_not_in(list[char*] haystack, char* id):
	int i = 0
	while (i < haystack.length):
		assert_equal(0, dag_id_equal(id, haystack[i]))
		i = i + 1


void test_linear_chain_generations_and_topo_order():
	dag* d = dag_new()
	int n = 6
	list[char*] ids = new list[char*]
	int i = 0
	while (i < n):
		char* id = vdt_make_id(i)
		ids.push(id)
		list[char*] parents = new list[char*]
		if (i > 0):
			parents.push(ids[i - 1])
		int gen = dag_add_node(d, id, parents)
		assert_equal(i, gen)
		i = i + 1

	assert_equal(n, dag_count(d))

	list[char*] topo = dag_topo_order(d)
	assert_equal(n, topo.length)
	i = 0
	while (i < n):
		assert_equal(1, dag_id_equal(ids[i], topo[i]))
		i = i + 1

	list[char*] rev = dag_topo_order_reverse(d)
	assert_equal(n, rev.length)
	i = 0
	while (i < n):
		assert_equal(1, dag_id_equal(ids[n - 1 - i], rev[i]))
		i = i + 1

	assert_equal(0, dag_parent_ids(d, ids[0]).length)
	i = 1
	while (i < n):
		list[char*] p = dag_parent_ids(d, ids[i])
		assert_equal(1, p.length)
		assert_equal(1, dag_id_equal(ids[i - 1], p[0]))
		i = i + 1


void test_diamond_merge_base_is_fork_point():
	dag* d = dag_new()
	char* r = vdt_make_id(100)
	list[char*] no_parents = new list[char*]
	dag_add_node(d, r, no_parents)
	char* a = vdt_make_id(101)
	dag_add_node(d, a, vdt_ids(r))
	char* b = vdt_make_id(102)
	dag_add_node(d, b, vdt_ids(r))
	char* a2 = vdt_make_id(103)
	dag_add_node(d, a2, vdt_ids(a))
	char* b2 = vdt_make_id(104)
	dag_add_node(d, b2, vdt_ids(b))

	assert_equal(0, dag_generation(d, r))
	assert_equal(1, dag_generation(d, a))
	assert_equal(1, dag_generation(d, b))
	assert_equal(2, dag_generation(d, a2))
	assert_equal(2, dag_generation(d, b2))

	list[char*] mb = dag_merge_base(d, a2, b2)
	assert_equal(1, mb.length)
	assert_equal(1, dag_id_equal(r, mb[0]))

	# merge-base is symmetric
	list[char*] mb_swapped = dag_merge_base(d, b2, a2)
	assert_equal(1, mb_swapped.length)
	assert_equal(1, dag_id_equal(r, mb_swapped[0]))

	assert_equal(1, dag_is_ancestor(d, r, a2))
	assert_equal(1, dag_is_ancestor(d, r, b2))
	assert_equal(1, dag_is_ancestor(d, a, a2))
	assert_equal(0, dag_is_ancestor(d, a2, b2))
	assert_equal(0, dag_is_ancestor(d, b2, a2))
	assert_equal(0, dag_is_ancestor(d, b2, r))
	assert_equal(1, dag_is_ancestor(d, a2, a2))


void test_criss_cross_two_best_common_ancestors():
	dag* d = dag_new()
	char* r = vdt_make_id(200)
	list[char*] no_parents = new list[char*]
	dag_add_node(d, r, no_parents)
	char* x = vdt_make_id(201)
	dag_add_node(d, x, vdt_ids(r))
	char* y = vdt_make_id(202)
	dag_add_node(d, y, vdt_ids(r))

	# Two merges that cross each other's parents: neither x nor y is an
	# ancestor of the other, and both are common ancestors of a and b,
	# so both are "best" (git's classic criss-cross shape).
	char* a = vdt_make_id(203)
	dag_add_node(d, a, vdt_ids2(x, y))
	char* b = vdt_make_id(204)
	dag_add_node(d, b, vdt_ids2(y, x))

	assert_equal(0, dag_is_ancestor(d, x, y))
	assert_equal(0, dag_is_ancestor(d, y, x))

	list[char*] mb = dag_merge_base(d, a, b)
	assert_equal(2, mb.length)
	# Deterministic order: ascending insertion sequence -- x was added
	# before y, so x comes first regardless of parent-list order above.
	assert_equal(1, dag_id_equal(x, mb[0]))
	assert_equal(1, dag_id_equal(y, mb[1]))

	# r is a common ancestor too, but not a *best* one (it is an
	# ancestor of both x and y), so it must not appear in the result.
	vdt_assert_not_in(mb, r)


void test_generation_numbers_deep_chain():
	dag* d = dag_new()
	int n = 200
	char* prev = 0
	int i = 0
	while (i < n):
		char* id = vdt_make_id(i)
		list[char*] parents = new list[char*]
		if (i > 0):
			parents.push(prev)
		int gen = dag_add_node(d, id, parents)
		assert_equal(i, gen)
		assert_equal(i, dag_generation(d, id))
		prev = id
		i = i + 1


void test_reachability_positive_and_negative():
	dag* d = dag_new()
	list[char*] no_parents = new list[char*]
	char* r = vdt_make_id(300)
	dag_add_node(d, r, no_parents)
	char* c1 = vdt_make_id(301)
	dag_add_node(d, c1, vdt_ids(r))
	char* c2 = vdt_make_id(302)
	dag_add_node(d, c2, vdt_ids(c1))
	list[char*] no_parents2 = new list[char*]
	char* other_root = vdt_make_id(303)
	dag_add_node(d, other_root, no_parents2)
	char* other_child = vdt_make_id(304)
	dag_add_node(d, other_child, vdt_ids(other_root))

	assert_equal(1, dag_is_ancestor(d, r, r))
	assert_equal(1, dag_is_ancestor(d, r, c1))
	assert_equal(1, dag_is_ancestor(d, r, c2))
	assert_equal(1, dag_is_ancestor(d, c1, c2))
	assert_equal(0, dag_is_ancestor(d, c1, r))
	assert_equal(0, dag_is_ancestor(d, c2, c1))
	assert_equal(0, dag_is_ancestor(d, r, other_child))
	assert_equal(0, dag_is_ancestor(d, other_root, c2))
	assert_equal(1, dag_is_ancestor(d, other_root, other_child))


int VDT_FUZZ_SEED():
	return 20260711


int VDT_FUZZ_NODE_COUNT():
	return 300


int VDT_FUZZ_MAX_PARENTS():
	return 4


# ancestors[i]: bitset of indices that are true (strict) ancestors of
# node i, computed bottom-up in index order (index order is topological
# here by construction: every parent index is < its child's index). This
# is an independent reference implementation -- it does not call any
# dag.w function -- used to cross-check dag_is_ancestor at scale. A
# bitset (rather than a list checked with linear "in" scans) keeps each
# union O(n) instead of O(n * current-set-size): ancestor sets in a
# lightly-connected random DAG quickly approach "most of the graph", so
# the naive list version is quadratic in the set size on top of the
# O(n) outer loop.
list[bitset*] vdt_compute_all_ancestors(list[list[int]] parent_indices, int n):
	list[bitset*] anc = new list[bitset*]
	int i = 0
	while (i < n):
		bitset* a = bitset_new(n)
		list[int] pidx = parent_indices[i]
		int j = 0
		while (j < pidx.length):
			int p = pidx[j]
			bitset_set(a, p)
			bitset_or(a, anc[p])
			j = j + 1
		anc.push(a)
		i = i + 1
	return anc


void test_randomized_dag_topo_and_reachability_invariants():
	fuzz_seed(VDT_FUZZ_SEED())
	dag* d = dag_new()
	int n = VDT_FUZZ_NODE_COUNT()
	list[char*] ids = new list[char*]
	list[list[int]] parent_indices = new list[list[int]]

	int i = 0
	while (i < n):
		char* id = vdt_make_id(i)
		ids.push(id)
		list[int] pidx = new list[int]
		list[char*] parent_ids = new list[char*]
		if (i > 0):
			int max_parents = i
			if (max_parents > VDT_FUZZ_MAX_PARENTS()):
				max_parents = VDT_FUZZ_MAX_PARENTS()
			int want = fuzz_range(max_parents + 1)
			int tries = 0
			int budget = want * 8 + 8
			while ((pidx.length < want) && (tries < budget)):
				int cand = fuzz_range(i)
				tries = tries + 1
				if ((cand in pidx) == 0):
					pidx.push(cand)
					parent_ids.push(ids[cand])
		int gen = dag_add_node(d, id, parent_ids)

		# Independent generation check: 0 for a root, else 1 + max over
		# parent generations, computed from this test's own bookkeeping.
		int want_gen = 0
		int j = 0
		while (j < pidx.length):
			int pgen = dag_generation(d, ids[pidx[j]])
			if (pgen + 1 > want_gen):
				want_gen = pgen + 1
			j = j + 1
		assert_equal(want_gen, gen)

		parent_indices.push(pidx)
		i = i + 1

	assert_equal(n, dag_count(d))

	# Topo order equals insertion order (this module's core invariant),
	# and every parent index must precede its child's index.
	list[char*] topo = dag_topo_order(d)
	assert_equal(n, topo.length)
	i = 0
	while (i < n):
		assert_equal(1, dag_id_equal(ids[i], topo[i]))
		list[int] pidx = parent_indices[i]
		int j = 0
		while (j < pidx.length):
			assert_equal(1, pidx[j] < i)
			j = j + 1
		i = i + 1

	list[bitset*] all_ancestors = vdt_compute_all_ancestors(parent_indices, n)

	i = 0
	while (i < n):
		bitset* reachable = all_ancestors[i]
		int k = 0
		while (k < n):
			int want = 0
			if (k == i):
				want = 1
			else if (bitset_get(reachable, k)):
				want = 1
			int got = dag_is_ancestor(d, ids[k], ids[i])
			assert_equal(want, got)
			k = k + 1
		i = i + 1
