/*
Counter: a multiset of strings, after Python's collections.Counter.

A counter wraps a built-in map[char*, int]. The map clones every key on
insert and frees the clones in counter_free, so callers may pass
temporary or stack strings. Missing keys read as 0 (counter_get never
inserts). Counts may be zero or negative; like Python, only the
"multiset" operations (counter_plus, counter_minus, counter_union,
counter_intersection) and counter_elements drop non-positive counts.

Ordering follows the map's insertion order (Python 3.7+ dict
semantics): a key keeps the position of its first insertion until it is
removed. counter_most_common breaks ties by that order, exactly as
Python's sorted(..., key=count, reverse=True) does.

Borrowed keys: the char* values in lists returned by counter_most_common
and counter_elements point at the counter's own key copies. They stay
valid until that key is removed or the counter is cleared or freed;
free only the list itself (l.free()).

The underlying map is the public field `counts`, so callers can iterate
with `for char* k, int n in c.counts` (do not mutate while iterating).
*/
import lib.lib


struct counter:
	map[char*, int] counts


counter* counter_new():
	counter* c = new counter()
	c.counts = new map[char*, int]
	return c


void counter_free(counter* c):
	if (c == 0): return
	c.counts.free()
	free(c)


counter* counter_copy(counter* c):
	counter* out = counter_new()
	for char* k, int n in c.counts:
		out.counts[k] = n
	return out


# c[key]; 0 for a missing key (the key is not inserted).
int counter_get(counter* c, char* key):
	return c.counts.get(key, 0)


void counter_set(counter* c, char* key, int count):
	c.counts[key] = count


# c[key] += n; inserts a missing key. Returns the new count.
int counter_add(counter* c, char* key, int n):
	return c.counts.add(key, n)


bool counter_contains(counter* c, char* key):
	return key in c.counts


# del c[key]; returns whether the key was present.
bool counter_remove(counter* c, char* key):
	return c.counts.remove(key)


# len(c): the number of distinct keys, whatever their counts.
int counter_length(counter* c):
	return c.counts.length


void counter_clear(counter* c):
	c.counts.free()
	c.counts = new map[char*, int]


# c.total(): the sum of all counts.
int counter_total(counter* c):
	int total = 0
	for char* k, int n in c.counts:
		total = total + n
	return total


# c.update(iterable): add one per occurrence.
void counter_update(counter* c, list[char*] items):
	for char* item in items:
		c.counts.add(item, 1)


# Counter(iterable): count each item of the list.
counter* counter_from_list(list[char*] items):
	counter* c = counter_new()
	counter_update(c, items)
	return c


# c.subtract(iterable): subtract one per occurrence (counts may go <= 0).
void counter_subtract(counter* c, list[char*] items):
	for char* item in items:
		c.counts.add(item, -1)


# c.update(other): add other's counts into c (keeps zero/negative results).
void counter_update_counter(counter* c, counter* other):
	for char* k, int n in other.counts:
		c.counts.add(k, n)


# c.subtract(other): subtract other's counts from c (keeps zero/negative).
void counter_subtract_counter(counter* c, counter* other):
	for char* k, int n in other.counts:
		c.counts.add(k, 0 - n)


# Stable merge sort of positions by descending count.
void counter_sort_desc(list[int] order, list[int] counts):
	int n = order.length
	if (n < 2): return
	list[int] tmp = new list[int]
	for i in range(n): tmp.push(0)
	int width = 1
	while (width < n):
		int lo = 0
		while (lo < n):
			int mid = lo + width
			if (mid > n): mid = n
			int hi = lo + 2 * width
			if (hi > n): hi = n
			int i = lo
			int j = mid
			int k = lo
			while (k < hi):
				# Take from the left run unless the right one is strictly
				# larger: ties keep their earlier (insertion) position.
				if (i < mid && (j >= hi || counts[order[i]] >= counts[order[j]])):
					tmp[k] = order[i]
					i = i + 1
				else:
					tmp[k] = order[j]
					j = j + 1
				k = k + 1
			lo = hi
		for m in range(n): order[m] = tmp[m]
		width = width * 2
	tmp.free()


# c.most_common(n): the n keys with the highest counts, highest first,
# ties in insertion order. n < 0 means all keys (Python's n=None).
# Read each count with counter_get. Keys are borrowed (see header).
list[char*] counter_most_common(counter* c, int n):
	list[char*] keys = new list[char*]
	list[int] counts = new list[int]
	list[int] order = new list[int]
	for char* k, int v in c.counts:
		order.push(keys.length)
		keys.push(k)
		counts.push(v)
	counter_sort_desc(order, counts)
	int limit = order.length
	if (n >= 0 && n < limit): limit = n
	list[char*] out = new list[char*]
	for i in range(limit): out.push(keys[order[i]])
	keys.free()
	counts.free()
	order.free()
	return out


# c.elements(): each key repeated count times, in insertion order; keys
# with counts < 1 are skipped. Keys are borrowed (see header).
list[char*] counter_elements(counter* c):
	list[char*] out = new list[char*]
	for char* k, int n in c.counts:
		for i in range(n): out.push(k)
	return out


# a + b: sum of counts, keeping only positive results.
counter* counter_plus(counter* a, counter* b):
	counter* out = counter_new()
	for char* k, int n in a.counts:
		int sum = n + b.counts.get(k, 0)
		if (sum > 0): out.counts[k] = sum
	for char* k, int n in b.counts:
		if (!(k in a.counts) && n > 0): out.counts[k] = n
	return out


# a - b: difference of counts, keeping only positive results.
counter* counter_minus(counter* a, counter* b):
	counter* out = counter_new()
	for char* k, int n in a.counts:
		int diff = n - b.counts.get(k, 0)
		if (diff > 0): out.counts[k] = diff
	for char* k, int n in b.counts:
		if (!(k in a.counts) && n < 0): out.counts[k] = 0 - n
	return out


# a | b: maximum of counts, keeping only positive results.
counter* counter_union(counter* a, counter* b):
	counter* out = counter_new()
	for char* k, int n in a.counts:
		int other = b.counts.get(k, 0)
		int best = n
		if (other > best): best = other
		if (best > 0): out.counts[k] = best
	for char* k, int n in b.counts:
		if (!(k in a.counts) && n > 0): out.counts[k] = n
	return out


# a & b: minimum of counts, keeping only positive results.
counter* counter_intersection(counter* a, counter* b):
	counter* out = counter_new()
	for char* k, int n in a.counts:
		int other = b.counts.get(k, 0)
		int least = n
		if (other < least): least = other
		if (least > 0): out.counts[k] = least
	return out


# a == b with missing keys treated as zero (Python 3.10+).
bool counter_equal(counter* a, counter* b):
	for char* k, int n in a.counts:
		if (n != b.counts.get(k, 0)): return false
	for char* k, int n in b.counts:
		if (n != a.counts.get(k, 0)): return false
	return true
