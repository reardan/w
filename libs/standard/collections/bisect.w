/*
Binary search over sorted sequences, after Python's bisect module
(docs/projects/stdlib_python_parity.md P2.8,
libs/standard/plans/03_numeric_data.md "collections/bisect.w").

Every search returns an insertion point in [lo, hi]:

	bisect_left   first index whose element is >= x (before equal runs)
	bisect_right  first index whose element is >  x (after equal runs)

and insort_left / insort_right insert x there, keeping the list sorted.
insort is insort_right, as in Python.

Families (all take Python's lo/hi bounds; hi = -1 stands for the list
length, Python's hi=None; lo < 0 traps, like Python's ValueError):

	bisect_left / bisect_right / insort_left / insort_right / insort
		list[int], signed integer order
	bisect_left_str / ... / insort_str
		list[char*], strcmp (byte) order -- Python's str order for ASCII
		and for UTF-8 text compared code point by code point
	bisect_left_by[T] / ... / insort_by[T]
		any word-sized element type, ordered by a comparator
		cmp(a, b) < 0 / == 0 / > 0, called with both values cast to int
		(generic: write bisect_left_by[point*](...) when T is not
		inferable from x)
	bisect_left_key / bisect_right_key
		list[int] with Python's key=: the key function is applied to the
		elements, not to x (x is already a key)
	bisect_left_int / bisect_right_int
		raw int* + length (the area plan's array form)

The list must already be sorted in the order used; as in Python, an
unsorted list gives an unspecified (but in-range) result.
*/
import lib.assert


type bisect_cmp = fn(int, int) -> int
type bisect_key = fn(int) -> int


# Resolves hi = -1 to length and checks the bounds; returns hi.
int bisect_check_bounds(int lo, int hi, int length):
	asserts(c"bisect: lo must be non-negative", lo >= 0)
	if (hi == -1): return length
	asserts(c"bisect: hi out of range", (hi >= 0) && (hi <= length))
	return hi


# --- list[int] ----------------------------------------------------------

int bisect_left(list[int] a, int x, int lo = 0, int hi = -1):
	hi = bisect_check_bounds(lo, hi, a.length)
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (a[mid] < x): lo = mid + 1
		else: hi = mid
	return lo


int bisect_right(list[int] a, int x, int lo = 0, int hi = -1):
	hi = bisect_check_bounds(lo, hi, a.length)
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (x < a[mid]): hi = mid
		else: lo = mid + 1
	return lo


# Python's bisect.bisect is bisect_right.
int bisect(list[int] a, int x, int lo = 0, int hi = -1):
	return bisect_right(a, x, lo, hi)


void insort_left(list[int] a, int x, int lo = 0, int hi = -1):
	a.insert(bisect_left(a, x, lo, hi), x)


void insort_right(list[int] a, int x, int lo = 0, int hi = -1):
	a.insert(bisect_right(a, x, lo, hi), x)


void insort(list[int] a, int x, int lo = 0, int hi = -1):
	insort_right(a, x, lo, hi)


# --- list[char*] in strcmp order ----------------------------------------

int bisect_left_str(list[char*] a, char* x, int lo = 0, int hi = -1):
	hi = bisect_check_bounds(lo, hi, a.length)
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (strcmp(a[mid], x) < 0): lo = mid + 1
		else: hi = mid
	return lo


int bisect_right_str(list[char*] a, char* x, int lo = 0, int hi = -1):
	hi = bisect_check_bounds(lo, hi, a.length)
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (strcmp(x, a[mid]) < 0): hi = mid
		else: lo = mid + 1
	return lo


# Stores the pointer x (not a copy); the caller keeps owning the string.
void insort_left_str(list[char*] a, char* x, int lo = 0, int hi = -1):
	a.insert(bisect_left_str(a, x, lo, hi), x)


void insort_right_str(list[char*] a, char* x, int lo = 0, int hi = -1):
	a.insert(bisect_right_str(a, x, lo, hi), x)


void insort_str(list[char*] a, char* x, int lo = 0, int hi = -1):
	insort_right_str(a, x, lo, hi)


# --- comparator (generic over word-sized T) -----------------------------
# Generic definitions cannot take default arguments, so lo and hi are
# explicit: pass 0, -1 for the whole list.

int bisect_left_by[T](list[T] a, T x, bisect_cmp* cmp, int lo, int hi):
	hi = bisect_check_bounds(lo, hi, a.length)
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (cmp(cast(int, a[mid]), cast(int, x)) < 0): lo = mid + 1
		else: hi = mid
	return lo


int bisect_right_by[T](list[T] a, T x, bisect_cmp* cmp, int lo, int hi):
	hi = bisect_check_bounds(lo, hi, a.length)
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (cmp(cast(int, x), cast(int, a[mid])) < 0): hi = mid
		else: lo = mid + 1
	return lo


void insort_left_by[T](list[T] a, T x, bisect_cmp* cmp, int lo, int hi):
	a.insert(bisect_left_by[T](a, x, cmp, lo, hi), x)


void insort_right_by[T](list[T] a, T x, bisect_cmp* cmp, int lo, int hi):
	a.insert(bisect_right_by[T](a, x, cmp, lo, hi), x)


void insort_by[T](list[T] a, T x, bisect_cmp* cmp, int lo, int hi):
	insort_right_by[T](a, x, cmp, lo, hi)


# --- key function (Python's key=) ---------------------------------------
# The list must be sorted by key(element); x is compared as a key.

int bisect_left_key(list[int] a, int x, bisect_key* key, int lo = 0, int hi = -1):
	hi = bisect_check_bounds(lo, hi, a.length)
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (key(a[mid]) < x): lo = mid + 1
		else: hi = mid
	return lo


int bisect_right_key(list[int] a, int x, bisect_key* key, int lo = 0, int hi = -1):
	hi = bisect_check_bounds(lo, hi, a.length)
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (x < key(a[mid])): hi = mid
		else: lo = mid + 1
	return lo


# --- raw arrays (int* + length) -----------------------------------------

int bisect_left_int(int* values, int length, int x):
	int lo = 0
	int hi = length
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (values[mid] < x): lo = mid + 1
		else: hi = mid
	return lo


int bisect_right_int(int* values, int length, int x):
	int lo = 0
	int hi = length
	while (lo < hi):
		int mid = lo + (hi - lo) / 2
		if (x < values[mid]): hi = mid
		else: lo = mid + 1
	return lo
