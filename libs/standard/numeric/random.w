/*
libs.standard.numeric.random: Python `random`-shaped API over lib/rand.w.

Deterministic and NOT cryptographic: every function takes an explicit
rand_state* (no hidden global generator), and a fixed seed reproduces
the same results bit-for-bit on every target, because everything here
is built on lib/rand.w's xorshift32 stream (rand_next31, the unbiased
rand_below, rand_float). The sequences are NOT Python's: CPython uses
MT19937, so the same seed gives different numbers than random.seed(n).
For secrets (tokens, keys, nonces) use libs/standard/crypto/secrets.w.

Split of responsibilities: lib/rand.w owns the generator and the small
primitives (rand_below, rand_range, rand_uniform, rand_expovariate,
rand_gaussian, rand_shuffle over a raw word array). This module adds
the Python-named facade and the container-level algorithms: choice,
sample (without replacement) and choices (with replacement, optional
weights or cumulative weights) over list[int].

Element type: W has no generic free functions, so the list algorithms
take list[int]. For other element types draw indices instead:
random_sample_indices / random_choices with a list of 0..n-1, or
random_randrange(r, 0, n, 1), and index your own container.

Errors follow lib/rand.w: invalid arguments (empty population, k out of
range, negative or all-zero weights, mismatched lengths) are fatal
asserts, mirroring Python's IndexError/ValueError. Returned lists are
newly allocated and owned by the caller (list_free[int]).

Width limits: populations and ranges are drawn with rand_below, so they
may hold at most 2^31 - 1 values.
*/
import lib.lib
import lib.assert
import lib.rand
import lib.container


# A heap-allocated generator seeded with seed (see rand_init: only the
# low 32 bits matter, and 0 folds to a fixed nonzero state). Release it
# with random_free.
rand_state* random_new(int seed):
	rand_state* r = new rand_state
	rand_init(r, seed)
	return r


void random_free(rand_state* r):
	free(r)


# Re-seed r in place (Python random.seed(n)); also clears the gauss cache.
void random_seed(rand_state* r, int seed):
	rand_init(r, seed)


# Python random(): float in [0, 1).
float random_float(rand_state* r):
	return rand_float(r)


# Python randrange(start, stop, step); see rand_range for the limits.
int random_randrange(rand_state* r, int start, int stop, int step):
	return rand_range(r, start, stop, step)


# Python randrange(start, stop) (the area plan's random_range).
int random_range(rand_state* r, int start, int stop):
	return rand_range(r, start, stop, 1)


# Python randint(a, b): a <= result <= b, both ends inclusive.
int random_randint(rand_state* r, int a, int b):
	return rand_range(r, a, b + 1, 1)


# Python uniform(a, b).
float random_uniform(rand_state* r, float a, float b):
	return rand_uniform(r, a, b)


# Python expovariate(lambd).
float random_expovariate(rand_state* r, float lambd):
	return rand_expovariate(r, lambd)


# Python gauss(mu, sigma) (Box-Muller with a cached second value, so
# it shares gauss's "not thread-safe per state" caveat).
float random_gauss(rand_state* r, float mu, float sigma):
	return rand_gaussian_scaled(r, mu, sigma)


# Python shuffle(x) over a raw array of n words.
void random_shuffle(rand_state* r, int* values, int n):
	rand_shuffle(r, values, n)


# Python shuffle(x) over a list, in place (same Fisher-Yates walk and
# therefore the same permutation as random_shuffle on an equal array).
void random_shuffle_list(rand_state* r, list[int] xs):
	int i = xs.length - 1
	while (i > 0):
		int j = rand_below(r, i + 1)
		int t = xs[i]
		xs[i] = xs[j]
		xs[j] = t
		i = i - 1


# Python choice(seq) over a raw array; fatal assert when n <= 0.
int random_choice(rand_state* r, int* values, int n):
	asserts(c"random_choice: empty sequence", n > 0)
	return values[rand_below(r, n)]


# Python choice(seq) over a list; fatal assert when it is empty.
int random_choice_list(rand_state* r, list[int] xs):
	asserts(c"random_choice: empty sequence", xs.length > 0)
	return xs[rand_below(r, xs.length)]


# k distinct indices drawn from range(n) without replacement, in
# selection order (so every prefix is itself a random sample). A
# partial Fisher-Yates walk over a 0..n-1 pool: O(n) time and memory,
# each k-permutation equally likely. Fatal assert unless 0 <= k <= n.
list[int] random_sample_indices(rand_state* r, int n, int k):
	asserts(c"random_sample: sample larger than population or negative", (k >= 0) && (k <= n))
	list[int] pool = new list[int]
	for i in range(n): pool.push(i)
	list[int] out = new list[int]
	for i in range(k):
		int j = i + rand_below(r, n - i)
		int picked = pool[j]
		pool[j] = pool[i]
		pool[i] = picked
		out.push(picked)
	list_free[int](pool)
	return out


# Python sample(population, k): k elements chosen without replacement
# (distinct positions; equal values may repeat if the population holds
# duplicates, as in Python). Fatal assert unless 0 <= k <= len.
list[int] random_sample(rand_state* r, list[int] population, int k):
	list[int] idx = random_sample_indices(r, population.length, k)
	list[int] out = new list[int]
	for i in range(idx.length): out.push(population[idx[i]])
	list_free[int](idx)
	return out


# Python choices(population, k=k): k elements with replacement, uniform.
# Fatal assert when the population is empty (and k > 0) or k < 0.
list[int] random_choices(rand_state* r, list[int] population, int k):
	asserts(c"random_choices: k must be non-negative", k >= 0)
	list[int] out = new list[int]
	if (k == 0): return out
	asserts(c"random_choices: empty population", population.length > 0)
	for i in range(k): out.push(population[rand_below(r, population.length)])
	return out


# Python choices(population, cum_weights=cum, k=k): with replacement,
# element i picked with probability (cum[i] - cum[i-1]) / cum[n-1].
# Each draw scales a uniform u in [0, 1) by the total and binary-searches
# for the first cumulative weight strictly greater (bisect_right, upper
# index clamped to n - 1 as CPython does), so zero-weight elements are
# never chosen. Fatal assert when lengths differ, the population is
# empty, cum decreases anywhere, or the total is not positive.
list[int] random_choices_cum(rand_state* r, list[int] population, list[float] cum, int k):
	asserts(c"random_choices: k must be non-negative", k >= 0)
	int n = population.length
	asserts(c"random_choices: number of weights does not match the population", cum.length == n)
	list[int] out = new list[int]
	if (k == 0): return out
	asserts(c"random_choices: empty population", n > 0)
	float prev = 0.0
	for i in range(n):
		asserts(c"random_choices: weights must be non-negative", cum[i] >= prev)
		prev = cum[i]
	float total = cum[n - 1]
	asserts(c"random_choices: total of weights must be greater than zero", total > 0.0)
	for d in range(k):
		float x = rand_float(r) * total
		int lo = 0
		int hi = n - 1
		while (lo < hi):
			int mid = (lo + hi) / 2
			if (x < cum[mid]): hi = mid
			else: lo = mid + 1
		out.push(population[lo])
	return out


# Python choices(population, weights=w, k=k): converts the relative
# weights to cumulative ones and defers to random_choices_cum. Same
# fatal asserts (a negative weight shows up as a decreasing cumulative).
list[int] random_choices_weighted(rand_state* r, list[int] population, list[float] weights, int k):
	asserts(c"random_choices: number of weights does not match the population", weights.length == population.length)
	list[float] cum = new list[float]
	float acc = 0.0
	for i in range(weights.length):
		asserts(c"random_choices: weights must be non-negative", weights[i] >= 0.0)
		acc = acc + weights[i]
		cum.push(acc)
	list[int] out = random_choices_cum(r, population, cum, k)
	list_free[float](cum)
	return out
