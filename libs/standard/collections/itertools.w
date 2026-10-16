/*
Combinatoric and run iterators after Python's itertools
(docs/projects/stdlib_python_parity.md P2.8). Output order matches
Python's for every function.

Index generators (lib/generator.w coroutines). The caller owns idx, a
list[int] the generator rewrites before every yield with the current
tuple of indices into the input pools; the yielded value is the
0-based ordinal of that tuple. Because all iteration state lives in idx,
abandoning a generator early (break out of a for loop, or gen_free)
leaks nothing. Do not modify idx while iterating; copy what you keep.

	permutations_indices(n, r, idx)    r-permutations of range(n),
	                                   r = -1 means r = n
	combinations_indices(n, r, idx)
	combinations_with_replacement_indices(n, r, idx)
	product_indices(sizes, repeat, idx)
	                                   one index per pool; sizes lists
	                                   the pool lengths, repeated
	                                   `repeat` times like product(...,
	                                   repeat=k)

	list[int] idx = new list[int]
	for int k in combinations_indices(4, 2, idx):
		use(xs[idx[0]], xs[idx[1]])
	idx.free()

Materializing helpers build a list of new lists (free them with
free_lists[T]). The plain names are list[int] shorthands that return a
new outer list; the generic _into forms take any word-sized element type
with an explicit type argument and append to a caller-owned outer list
(a generic function cannot return list[T]):

	list[list[char*]] out = new list[list[char*]]
	permutations_into[char*](names, 2, out)

	permutations / permutations_into[T]         (xs, r)   r = -1: len(xs)
	combinations / combinations_into[T]         (xs, r)
	combinations_with_replacement / ..._into[T] (xs, r)
	product / product_into[T]                   (pools, repeat)
	pairwise / pairwise_into[T]                 (xs)
	batched / batched_into[T]                   (xs, n)   n >= 1

Runs and folds over list[int]:

	group_by(xs)              runs of equal consecutive values (Python
	                          groupby without key; sort first to group
	                          all equal values)
	group_by_key(xs, key)     runs of equal key(x); the key of a run is
	                          key(run[0])
	group_by_str(xs)          list[char*] runs of strcmp-equal strings
	chain(lists)              generator over every value of every list
	chain_list(lists)         the same, materialized
	accumulate(xs, f)         generator of running f-folds (f = 0: +)
	accumulate_list(xs, f)    materialized; accumulate_list_initial adds
	                          Python's initial= value as the first item

Python's r > len, n == 0 and r == 0 edge cases behave as in CPython:
r > n yields nothing (permutations, combinations), r == 0 yields one
empty tuple, an empty pool makes product empty, and product of no pools
(or repeat = 0) yields one empty tuple.
*/
import lib.assert
import lib.generator


type itertools_key = fn(int) -> int
type itertools_binop = fn(int, int) -> int


# Sets idx to exactly r slots holding 0.
void itertools_reset_idx(list[int] idx, int r):
	idx.clear()
	for i in range(r): idx.push(0)


# 1 when v appears among idx[0 .. upto - 1].
int itertools_idx_has(list[int] idx, int upto, int v):
	for j in range(upto):
		if (idx[j] == v): return 1
	return 0


# --- index generators ---------------------------------------------------

# Lexicographic r-permutations of range(n) -- CPython's emission order.
# Steps from the current tuple alone: the rightmost position that can
# take a larger unused value takes the smallest such, and everything to
# its right is refilled with the smallest unused values in ascending
# order.
generator int permutations_indices(int n, int r, list[int] idx):
	if (r == -1): r = n
	asserts(c"permutations: r must be non-negative", r >= 0)
	if (r > n): return
	itertools_reset_idx(idx, r)
	for i in range(r): idx[i] = i
	int ordinal = 0
	yield ordinal
	while (1):
		int i = r - 1
		while (i >= 0):
			int v = idx[i] + 1
			while ((v < n) && itertools_idx_has(idx, i, v)): v = v + 1
			if (v < n):
				idx[i] = v
				break
			i = i - 1
		if (i < 0): return
		int j = i + 1
		while (j < r):
			int w = 0
			while (itertools_idx_has(idx, j, w)): w = w + 1
			idx[j] = w
			j = j + 1
		ordinal = ordinal + 1
		yield ordinal


generator int combinations_indices(int n, int r, list[int] idx):
	asserts(c"combinations: r must be non-negative", r >= 0)
	if (r > n): return
	itertools_reset_idx(idx, r)
	for i in range(r): idx[i] = i
	int ordinal = 0
	yield ordinal
	while (1):
		int i = r - 1
		while ((i >= 0) && (idx[i] == i + n - r)): i = i - 1
		if (i < 0): return
		idx[i] = idx[i] + 1
		int j = i + 1
		while (j < r):
			idx[j] = idx[j - 1] + 1
			j = j + 1
		ordinal = ordinal + 1
		yield ordinal


generator int combinations_with_replacement_indices(int n, int r, list[int] idx):
	asserts(c"combinations_with_replacement: r must be non-negative", r >= 0)
	if ((n == 0) && (r > 0)): return
	itertools_reset_idx(idx, r)
	int ordinal = 0
	yield ordinal
	while (1):
		int i = r - 1
		while ((i >= 0) && (idx[i] == n - 1)): i = i - 1
		if (i < 0): return
		int v = idx[i] + 1
		int j = i
		while (j < r):
			idx[j] = v
			j = j + 1
		ordinal = ordinal + 1
		yield ordinal


# Cartesian product, rightmost index fastest (an odometer). Pool k has
# sizes[k % sizes.length] items.
generator int product_indices(list[int] sizes, int repeat, list[int] idx):
	asserts(c"product: repeat must be non-negative", repeat >= 0)
	int m = sizes.length * repeat
	for k in range(sizes.length):
		if ((repeat > 0) && (sizes[k] <= 0)): return
	itertools_reset_idx(idx, m)
	int ordinal = 0
	yield ordinal
	while (1):
		int i = m - 1
		while (i >= 0):
			idx[i] = idx[i] + 1
			if (idx[i] < sizes[i % sizes.length]): break
			idx[i] = 0
			i = i - 1
		if (i < 0): return
		ordinal = ordinal + 1
		yield ordinal


# --- materializing helpers (generic) ------------------------------------

# Frees every inner list and then the outer one.
void free_lists[T](list[list[T]] lists):
	for list[T] inner in lists: inner.free()
	lists.free()


# Generic definitions cannot return list[T] (the return type is parsed
# before the type parameters), so these append to a caller-owned out.

void itertools_pick_into[T](list[T] xs, list[int] idx, list[list[T]] out):
	list[T] row = new list[T]
	for int i in idx: row.push(xs[i])
	out.push(row)


void permutations_into[T](list[T] xs, int r, list[list[T]] out):
	list[int] idx = new list[int]
	for int k in permutations_indices(xs.length, r, idx): itertools_pick_into[T](xs, idx, out)
	idx.free()


void combinations_into[T](list[T] xs, int r, list[list[T]] out):
	list[int] idx = new list[int]
	for int k in combinations_indices(xs.length, r, idx): itertools_pick_into[T](xs, idx, out)
	idx.free()


void combinations_with_replacement_into[T](list[T] xs, int r, list[list[T]] out):
	list[int] idx = new list[int]
	for int k in combinations_with_replacement_indices(xs.length, r, idx): itertools_pick_into[T](xs, idx, out)
	idx.free()


# product(*pools, repeat=repeat)
void product_into[T](list[list[T]] pools, int repeat, list[list[T]] out):
	list[int] sizes = new list[int]
	for list[T] pool in pools: sizes.push(pool.length)
	list[int] idx = new list[int]
	for int k in product_indices(sizes, repeat, idx):
		list[T] row = new list[T]
		for i in range(idx.length): row.push(pools[i % pools.length][idx[i]])
		out.push(row)
	idx.free()
	sizes.free()


void pairwise_into[T](list[T] xs, list[list[T]] out):
	int i = 0
	while (i + 1 < xs.length):
		list[T] pair = new list[T]
		pair.push(xs[i])
		pair.push(xs[i + 1])
		out.push(pair)
		i = i + 1


void batched_into[T](list[T] xs, int n, list[list[T]] out):
	asserts(c"batched: n must be at least one", n >= 1)
	int i = 0
	while (i < xs.length):
		list[T] batch = new list[T]
		int j = i
		while ((j < xs.length) && (j < i + n)):
			batch.push(xs[j])
			j = j + 1
		out.push(batch)
		i = j


# --- list[int] shorthands -----------------------------------------------

list[list[int]] permutations(list[int] xs, int r = -1):
	list[list[int]] out = new list[list[int]]
	permutations_into[int](xs, r, out)
	return out


list[list[int]] combinations(list[int] xs, int r):
	list[list[int]] out = new list[list[int]]
	combinations_into[int](xs, r, out)
	return out


list[list[int]] combinations_with_replacement(list[int] xs, int r):
	list[list[int]] out = new list[list[int]]
	combinations_with_replacement_into[int](xs, r, out)
	return out


list[list[int]] product(list[list[int]] pools, int repeat = 1):
	list[list[int]] out = new list[list[int]]
	product_into[int](pools, repeat, out)
	return out


list[list[int]] pairwise(list[int] xs):
	list[list[int]] out = new list[list[int]]
	pairwise_into[int](xs, out)
	return out


list[list[int]] batched(list[int] xs, int n):
	list[list[int]] out = new list[list[int]]
	batched_into[int](xs, n, out)
	return out


# --- runs ---------------------------------------------------------------

list[list[int]] group_by_key(list[int] xs, itertools_key* key):
	list[list[int]] out = new list[list[int]]
	int i = 0
	while (i < xs.length):
		list[int] run = new list[int]
		int k = xs[i]
		if (key != 0): k = key(xs[i])
		run.push(xs[i])
		i = i + 1
		while (i < xs.length):
			int kj = xs[i]
			if (key != 0): kj = key(xs[i])
			if (kj != k): break
			run.push(xs[i])
			i = i + 1
		out.push(run)
	return out


list[list[int]] group_by(list[int] xs):
	return group_by_key(xs, 0)


# The runs hold the original pointers; the caller keeps owning the strings.
list[list[char*]] group_by_str(list[char*] xs):
	list[list[char*]] out = new list[list[char*]]
	int i = 0
	while (i < xs.length):
		list[char*] run = new list[char*]
		char* first = xs[i]
		run.push(first)
		i = i + 1
		while ((i < xs.length) && (strcmp(xs[i], first) == 0)):
			run.push(xs[i])
			i = i + 1
		out.push(run)
	return out


# --- chain / accumulate -------------------------------------------------

generator int chain(list[list[int]] lists):
	for list[int] inner in lists:
		for int v in inner: yield v


list[int] chain_list(list[list[int]] lists):
	list[int] out = new list[int]
	for list[int] inner in lists:
		for int v in inner: out.push(v)
	return out


int itertools_apply(itertools_binop* f, int acc, int v):
	if (f == 0): return acc + v
	return f(acc, v)


# Running totals (f = 0) or running f(acc, x) folds, first item as-is.
generator int accumulate(list[int] xs, itertools_binop* f):
	int acc = 0
	for i in range(xs.length):
		if (i == 0): acc = xs[0]
		else: acc = itertools_apply(f, acc, xs[i])
		yield acc


list[int] accumulate_list(list[int] xs, itertools_binop* f = 0):
	list[int] out = new list[int]
	for i in range(xs.length):
		if (i == 0): out.push(xs[0])
		else: out.push(itertools_apply(f, out[i - 1], xs[i]))
	return out


# accumulate(xs, f, initial=initial): initial comes first, then the folds.
list[int] accumulate_list_initial(list[int] xs, itertools_binop* f, int initial):
	list[int] out = new list[int]
	int acc = initial
	out.push(acc)
	for int v in xs:
		acc = itertools_apply(f, acc, v)
		out.push(acc)
	return out
