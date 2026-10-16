# wbuild: x64
# wbuild: step="bin/itertools_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import structures.string
import libs.standard.collections.itertools

# Expected strings are CPython 3.12 reprs, e.g.
# list(itertools.permutations(range(4), 2)).


void append_tuple(string_builder* s, list[int] t):
	string_append(s, c"(")
	for i in range(t.length):
		if (i > 0): string_append(s, c", ")
		string_append_int(s, t[i])
	if (t.length == 1): string_append(s, c",")
	string_append(s, c")")


# Python repr of a list of tuples; frees the lists.
void expect_tuples(char* want, list[list[int]] got):
	string_builder* s = string_new()
	string_append(s, c"[")
	for i in range(got.length):
		if (i > 0): string_append(s, c", ")
		append_tuple(s, got[i])
	string_append(s, c"]")
	assert_strings_equal(want, s.data)
	string_free(s)
	free_lists[int](got)


# Python repr of a list of lists; frees the lists.
void expect_lists(char* want, list[list[int]] got):
	string_builder* s = string_new()
	string_append(s, c"[")
	for i in range(got.length):
		if (i > 0): string_append(s, c", ")
		string_append(s, c"[")
		list[int] inner = got[i]
		for j in range(inner.length):
			if (j > 0): string_append(s, c", ")
			string_append_int(s, inner[j])
		string_append(s, c"]")
	string_append(s, c"]")
	assert_strings_equal(want, s.data)
	string_free(s)
	free_lists[int](got)


# Python repr of a flat list; frees it.
void expect_list(char* want, list[int] got):
	string_builder* s = string_new()
	for int v in got:
		if (s.length > 0): string_append(s, c", ")
		string_append_int(s, v)
	char* text = s.data
	string_builder* full = string_new()
	string_append(full, c"[")
	string_append(full, text)
	string_append(full, c"]")
	assert_strings_equal(want, full.data)
	string_free(s)
	string_free(full)
	got.free()


list[int] range_list(int n):
	list[int] out = new list[int]
	for i in range(n): out.push(i)
	return out


int max_op(int a, int b):
	if (a > b): return a
	return b


int abs_key(int v):
	if (v < 0): return 0 - v
	return v


void test_permutations():
	list[int] r4 = range_list(4)
	expect_tuples(c"[(0, 1), (0, 2), (0, 3), (1, 0), (1, 2), (1, 3), (2, 0), (2, 1), (2, 3), (3, 0), (3, 1), (3, 2)]", permutations(r4, 2))
	expect_tuples(c"[(0,), (1,), (2,), (3,)]", permutations(r4, 1))
	list[int] xs = list[int]{10, 20, 30}
	expect_tuples(c"[(10, 20, 30), (10, 30, 20), (20, 10, 30), (20, 30, 10), (30, 10, 20), (30, 20, 10)]", permutations(xs))
	expect_tuples(c"[()]", permutations(xs, 0))
	expect_tuples(c"[]", permutations(xs, 4))
	list[int] empty = new list[int]
	expect_tuples(c"[()]", permutations(empty, 0))
	expect_tuples(c"[()]", permutations(empty))
	list[int] r6 = range_list(6)
	list[list[int]] all = permutations(r6)
	assert_equal(720, all.length)
	# strictly increasing lexicographic order, all distinct
	for i in range(1, all.length):
		list[int] a = all[i - 1]
		list[int] b = all[i]
		int j = 0
		while (a[j] == b[j]): j = j + 1
		asserts(c"lexicographic", a[j] < b[j])
	free_lists[int](all)
	r6.free()
	empty.free()
	xs.free()
	r4.free()


void test_combinations():
	list[int] r5 = range_list(5)
	expect_tuples(c"[(0, 1, 2), (0, 1, 3), (0, 1, 4), (0, 2, 3), (0, 2, 4), (0, 3, 4), (1, 2, 3), (1, 2, 4), (1, 3, 4), (2, 3, 4)]", combinations(r5, 3))
	list[int] xs = list[int]{1, 2, 3}
	expect_tuples(c"[()]", combinations(xs, 0))
	list[int] two = list[int]{1, 2}
	expect_tuples(c"[]", combinations(two, 3))
	list[int] three = list[int]{7, 8, 9}
	expect_tuples(c"[(7, 8, 9)]", combinations(three, 3))
	list[int] r10 = range_list(10)
	list[list[int]] c = combinations(r10, 4)
	assert_equal(210, c.length)
	free_lists[int](c)
	r10.free()
	three.free()
	two.free()
	xs.free()
	r5.free()


void test_combinations_with_replacement():
	list[int] xs = list[int]{1, 2, 3}
	expect_tuples(c"[(1, 1), (1, 2), (1, 3), (2, 2), (2, 3), (3, 3)]", combinations_with_replacement(xs, 2))
	list[int] empty = new list[int]
	expect_tuples(c"[]", combinations_with_replacement(empty, 2))
	expect_tuples(c"[()]", combinations_with_replacement(empty, 0))
	list[int] one = list[int]{5}
	expect_tuples(c"[(5, 5, 5)]", combinations_with_replacement(one, 3))
	one.free()
	empty.free()
	xs.free()


void test_product():
	list[list[int]] pools = new list[list[int]]
	pools.push(list[int]{1, 2})
	pools.push(list[int]{3, 4, 5})
	expect_tuples(c"[(1, 3), (1, 4), (1, 5), (2, 3), (2, 4), (2, 5)]", product(pools))
	free_lists[int](pools)

	pools = new list[list[int]]
	pools.push(list[int]{0, 1})
	expect_tuples(c"[(0, 0, 0), (0, 0, 1), (0, 1, 0), (0, 1, 1), (1, 0, 0), (1, 0, 1), (1, 1, 0), (1, 1, 1)]", product(pools, 3))
	expect_tuples(c"[()]", product(pools, 0))
	free_lists[int](pools)

	pools = new list[list[int]]
	pools.push(list[int]{1, 2})
	pools.push(list[int]{3})
	expect_tuples(c"[(1, 3, 1, 3), (1, 3, 2, 3), (2, 3, 1, 3), (2, 3, 2, 3)]", product(pools, 2))
	free_lists[int](pools)

	pools = new list[list[int]]
	pools.push(list[int]{1, 2})
	pools.push(new list[int])
	pools.push(list[int]{3})
	expect_tuples(c"[]", product(pools))
	free_lists[int](pools)

	pools = new list[list[int]]
	expect_tuples(c"[()]", product(pools))
	pools.free()


void test_generic_strings():
	list[char*] names = list[char*]{c"a", c"b", c"c"}
	list[list[char*]] c = new list[list[char*]]
	combinations_into[char*](names, 2, c)
	assert_equal(3, c.length)
	assert_strings_equal(c"a", c[0][0])
	assert_strings_equal(c"b", c[0][1])
	assert_strings_equal(c"a", c[1][0])
	assert_strings_equal(c"c", c[1][1])
	assert_strings_equal(c"b", c[2][0])
	assert_strings_equal(c"c", c[2][1])
	free_lists[char*](c)
	list[list[char*]] p = new list[list[char*]]
	permutations_into[char*](names, 2, p)
	assert_equal(6, p.length)
	assert_strings_equal(c"c", p[5][0])
	assert_strings_equal(c"b", p[5][1])
	free_lists[char*](p)
	list[list[char*]] pools = new list[list[char*]]
	pools.push(names)
	list[list[char*]] q = new list[list[char*]]
	product_into[char*](pools, 2, q)
	assert_equal(9, q.length)
	assert_strings_equal(c"b", q[5][0])
	assert_strings_equal(c"c", q[5][1])
	free_lists[char*](q)
	free_lists[char*](pools) /* frees names too */


void test_index_generator_while_loop_and_ordinals():
	list[int] idx = new list[int]
	generator* g = combinations_indices(4, 2, idx)
	int count = 0
	while (gen_next(g)):
		assert_equal(count, gen_value(g))
		assert_equal(2, idx.length)
		asserts(c"increasing", idx[0] < idx[1])
		count = count + 1
	assert_equal(6, count)
	gen_free(g)
	idx.free()


void test_index_generator_break_does_not_leak():
	list[int] idx = new list[int]
	int seen = 0
	for int k in permutations_indices(8, -1, idx):
		seen = seen + 1
		if (k == 4): break
	assert_equal(5, seen)
	# (0, 1, 2, 3, 4, 5, 7, 6) is the 2nd permutation of range(8)
	for int k in permutations_indices(8, 8, idx):
		if (k == 1):
			assert_equal(7, idx[6])
			assert_equal(6, idx[7])
			break
	list[int] sizes = list[int]{3, 2}
	int last = -1
	for int k in product_indices(sizes, 1, idx):
		last = k
		if (k == 3):
			assert_equal(1, idx[0])
			assert_equal(1, idx[1])
	assert_equal(5, last)
	sizes.free()
	idx.free()


void test_pairwise_batched():
	list[int] xs = list[int]{1, 2, 3, 4}
	expect_tuples(c"[(1, 2), (2, 3), (3, 4)]", pairwise(xs))
	list[int] one = list[int]{1}
	expect_tuples(c"[]", pairwise(one))
	list[int] seven = list[int]{1, 2, 3, 4, 5, 6, 7}
	expect_tuples(c"[(1, 2, 3), (4, 5, 6), (7,)]", batched(seven, 3))
	list[int] two = list[int]{1, 2}
	expect_tuples(c"[(1, 2)]", batched(two, 2))
	list[int] empty = new list[int]
	expect_tuples(c"[]", batched(empty, 2))
	expect_tuples(c"[]", pairwise(empty))
	empty.free()
	two.free()
	seven.free()
	one.free()
	xs.free()


void test_group_by():
	list[int] xs = list[int]{1, 1, 2, 3, 3, 3, 1}
	expect_lists(c"[[1, 1], [2], [3, 3, 3], [1]]", group_by(xs))
	list[int] ys = list[int]{1, -1, 2, -2, -2, 3}
	expect_lists(c"[[1, -1], [2, -2, -2], [3]]", group_by_key(ys, abs_key))
	list[int] empty = new list[int]
	expect_lists(c"[]", group_by(empty))
	list[char*] words = list[char*]{c"a", c"a", c"b", c"a"}
	list[list[char*]] runs = group_by_str(words)
	assert_equal(3, runs.length)
	assert_equal(2, runs[0].length)
	assert_equal(1, runs[1].length)
	assert_strings_equal(c"b", runs[1][0])
	assert_strings_equal(c"a", runs[2][0])
	free_lists[char*](runs)
	words.free()
	empty.free()
	ys.free()
	xs.free()


void test_chain():
	list[list[int]] lists = new list[list[int]]
	lists.push(list[int]{1, 2})
	lists.push(new list[int])
	lists.push(list[int]{3})
	expect_list(c"[1, 2, 3]", chain_list(lists))
	int sum = 0
	int count = 0
	for int v in chain(lists):
		sum = sum + v
		count = count + 1
	assert_equal(6, sum)
	assert_equal(3, count)
	free_lists[int](lists)


void test_accumulate():
	list[int] xs = list[int]{1, 2, 3, 4, 5}
	expect_list(c"[1, 3, 6, 10, 15]", accumulate_list(xs))
	list[int] ys = list[int]{3, 1, 4, 1, 5}
	expect_list(c"[3, 3, 4, 4, 5]", accumulate_list(ys, max_op))
	list[int] zs = list[int]{1, 2, 3}
	expect_list(c"[100, 101, 103, 106]", accumulate_list_initial(zs, 0, 100))
	list[int] empty = new list[int]
	expect_list(c"[7]", accumulate_list_initial(empty, 0, 7))
	expect_list(c"[]", accumulate_list(empty))
	list[int] got = new list[int]
	for int v in accumulate(xs, 0): got.push(v)
	expect_list(c"[1, 3, 6, 10, 15]", got)
	empty.free()
	zs.free()
	ys.free()
	xs.free()
