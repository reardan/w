/*
LRU cache: a bounded key -> value map that evicts the least recently used
entry, after the cache behind Python's functools.lru_cache (the
decorator itself is a language feature and out of scope; this is the
explicit-struct form).

Two key kinds share one struct and one node layout:

	lru_cache* c = lru_new(128)        # char* keys: lru_get / lru_put / ...
	lru_cache* d = lru_int_new(128)    # int keys:   lru_get_int / lru_put_int / ...

Calling a string-key function on an int-key cache (or the reverse)
traps. String keys are copied on insert; the cache owns the copies.

Values are words (int; store pointers with cast(int, p)). Every
operation is O(1): a built-in map indexes the nodes of a doubly linked
recency list whose head is the most recently used entry and whose tail
is the next to be evicted.

Recency: lru_get / lru_lookup / lru_put touch an entry (make it most
recent); lru_peek and lru_contains do not. Statistics (Python's
cache_info): `hits` and `misses` count lru_get / lru_lookup outcomes;
`evictions` counts capacity evictions; `length` and `capacity` are the
current size and bound. Treat the fields as read-only.

Capacity: n > 0 bounds the cache at n entries; 0 caches nothing (every
put drops its value immediately, like maxsize=0); a negative capacity
is unbounded (maxsize=None).

Dropping values: an optional callback (lru_set_on_drop) is called for
every value the cache lets go of, so owned values can be freed:
capacity eviction, lru_put replacing a different value under an
existing key, lru_remove, lru_clear, lru_free, and a put into a
capacity-0 cache. lru_pop hands the value back to the caller instead
and does not call it. The callback receives the key (the char* key for
a string cache, valid only during the call, and 0 there for an int
cache; int_key is the int key, or 0 for a string cache) and the value.
It must not call back into the same cache.
*/
import lib.lib
import lib.stack_trace


type lru_drop_fn = fn(void*, char*, int, int) -> void


struct lru_node:
	char* key        # owned copy (string caches), else 0
	int int_key
	int value
	lru_node* prev   # toward the most recent end
	lru_node* next   # toward the least recent end


struct lru_cache:
	int capacity
	int length
	int hits
	int misses
	int evictions
	int int_keys     # 1 for an int-key cache
	lru_node* head   # most recently used
	lru_node* tail   # least recently used: next eviction
	map[char*, lru_node*] index
	map[int, lru_node*] int_index
	lru_drop_fn* on_drop
	void* context


void lru_trap(char* message):
	println2(message)
	print_stack_trace()
	exit(1)


lru_cache* lru_alloc(int capacity, int int_keys):
	lru_cache* c = new lru_cache()
	c.capacity = capacity
	c.length = 0
	c.hits = 0
	c.misses = 0
	c.evictions = 0
	c.int_keys = int_keys
	c.head = 0
	c.tail = 0
	c.index = new map[char*, lru_node*]
	c.int_index = new map[int, lru_node*]
	c.on_drop = 0
	c.context = 0
	return c


# A cache with char* keys holding at most capacity entries (< 0: unbounded).
lru_cache* lru_new(int capacity):
	return lru_alloc(capacity, 0)


# A cache with int keys holding at most capacity entries (< 0: unbounded).
lru_cache* lru_int_new(int capacity):
	return lru_alloc(capacity, 1)


void lru_set_on_drop(lru_cache* c, lru_drop_fn* callback, void* context):
	c.on_drop = callback
	c.context = context


void lru_require_kind(lru_cache* c, int int_keys):
	if (c.int_keys != int_keys):
		if (int_keys): lru_trap(c"lru: int-key operation on a string-key cache")
		lru_trap(c"lru: string-key operation on an int-key cache")


void lru_drop(lru_cache* c, char* key, int int_key, int value):
	if (c.on_drop != 0): c.on_drop(c.context, key, int_key, value)


void lru_unlink(lru_cache* c, lru_node* n):
	if (n.prev != 0): n.prev.next = n.next
	else: c.head = n.next
	if (n.next != 0): n.next.prev = n.prev
	else: c.tail = n.prev
	n.prev = 0
	n.next = 0


void lru_push_front(lru_cache* c, lru_node* n):
	n.prev = 0
	n.next = c.head
	if (c.head != 0): c.head.prev = n
	c.head = n
	if (c.tail == 0): c.tail = n


void lru_touch(lru_cache* c, lru_node* n):
	if (c.head == n): return
	lru_unlink(c, n)
	lru_push_front(c, n)


# Unlink n, drop it from the index and free the node. The caller owns
# (and frees) n.key afterwards; the value is not dropped here.
void lru_discard(lru_cache* c, lru_node* n):
	lru_unlink(c, n)
	if (c.int_keys): c.int_index.remove(n.int_key)
	else: c.index.remove(n.key)
	free(n)
	c.length = c.length - 1


void lru_evict_tail(lru_cache* c):
	lru_node* n = c.tail
	int int_key = n.int_key
	int value = n.value
	char* key = n.key
	lru_discard(c, n)
	c.evictions = c.evictions + 1
	lru_drop(c, key, int_key, value)
	if (key != 0): free(key)


# Insert a fresh node (key not present) and evict down to capacity.
void lru_insert(lru_cache* c, char* key, int int_key, int value):
	if (c.capacity == 0):
		lru_drop(c, key, int_key, value)
		return
	if (c.capacity > 0):
		while (c.length >= c.capacity): lru_evict_tail(c)
	lru_node* n = new lru_node()
	n.key = 0
	if (key != 0): n.key = strclone(key)
	n.int_key = int_key
	n.value = value
	n.prev = 0
	n.next = 0
	if (c.int_keys): c.int_index[int_key] = n
	else: c.index[n.key] = n
	lru_push_front(c, n)
	c.length = c.length + 1


void lru_replace(lru_cache* c, lru_node* n, int value):
	int old = n.value
	n.value = value
	lru_touch(c, n)
	if (old != value): lru_drop(c, n.key, n.int_key, old)


bool lru_hit(lru_cache* c, lru_node* n, int* out):
	if (n == 0):
		c.misses = c.misses + 1
		return false
	c.hits = c.hits + 1
	lru_touch(c, n)
	if (out != 0): out[0] = n.value
	return true


bool lru_take(lru_cache* c, lru_node* n, int* out, bool drop):
	if (n == 0): return false
	int value = n.value
	if (out != 0): out[0] = value
	char* key = n.key
	int int_key = n.int_key
	lru_discard(c, n)
	if (drop): lru_drop(c, key, int_key, value)
	if (key != 0): free(key)
	return true


lru_node* lru_find(lru_cache* c, char* key):
	lru_require_kind(c, 0)
	return c.index.get(key, 0)


lru_node* lru_find_int(lru_cache* c, int key):
	lru_require_kind(c, 1)
	return c.int_index.get(key, 0)


# --- string keys ---

# Look key up; on a hit store the value in *out (out may be 0), make the
# entry most recent and count a hit; on a miss count a miss.
bool lru_lookup(lru_cache* c, char* key, int* out):
	return lru_hit(c, lru_find(c, key), out)


# The value for key (counted and touched like lru_lookup), or missing.
int lru_get(lru_cache* c, char* key, int missing):
	int value = missing
	lru_lookup(c, key, &value)
	return value


# The value for key without touching recency or statistics, or missing.
int lru_peek(lru_cache* c, char* key, int missing):
	lru_node* n = lru_find(c, key)
	if (n == 0): return missing
	return n.value


bool lru_contains(lru_cache* c, char* key):
	return lru_find(c, key) != 0


# Insert or replace key's value and make it most recent, evicting the
# least recently used entry when the cache is full.
void lru_put(lru_cache* c, char* key, int value):
	lru_node* n = lru_find(c, key)
	if (n != 0): lru_replace(c, n, value)
	else: lru_insert(c, key, 0, value)


# Remove key, dropping its value through the callback.
bool lru_remove(lru_cache* c, char* key):
	return lru_take(c, lru_find(c, key), 0, true)


# Remove key and hand its value back in *out (no drop callback).
bool lru_pop(lru_cache* c, char* key, int* out):
	return lru_take(c, lru_find(c, key), out, false)


# Keys from least to most recently used (the eviction order). Borrowed:
# valid until the entry leaves the cache; free only the list.
list[char*] lru_keys(lru_cache* c):
	lru_require_kind(c, 0)
	list[char*] out = new list[char*]
	lru_node* n = c.tail
	while (n != 0):
		out.push(n.key)
		n = n.prev
	return out


# --- int keys ---

bool lru_lookup_int(lru_cache* c, int key, int* out):
	return lru_hit(c, lru_find_int(c, key), out)


int lru_get_int(lru_cache* c, int key, int missing):
	int value = missing
	lru_lookup_int(c, key, &value)
	return value


int lru_peek_int(lru_cache* c, int key, int missing):
	lru_node* n = lru_find_int(c, key)
	if (n == 0): return missing
	return n.value


bool lru_contains_int(lru_cache* c, int key):
	return lru_find_int(c, key) != 0


void lru_put_int(lru_cache* c, int key, int value):
	lru_node* n = lru_find_int(c, key)
	if (n != 0): lru_replace(c, n, value)
	else: lru_insert(c, 0, key, value)


bool lru_remove_int(lru_cache* c, int key):
	return lru_take(c, lru_find_int(c, key), 0, true)


bool lru_pop_int(lru_cache* c, int key, int* out):
	return lru_take(c, lru_find_int(c, key), out, false)


list[int] lru_int_keys(lru_cache* c):
	lru_require_kind(c, 1)
	list[int] out = new list[int]
	lru_node* n = c.tail
	while (n != 0):
		out.push(n.int_key)
		n = n.prev
	return out


# --- both kinds ---

# Change the bound, evicting least recently used entries as needed.
void lru_resize(lru_cache* c, int capacity):
	c.capacity = capacity
	if (capacity < 0): return
	while (c.length > capacity): lru_evict_tail(c)


# Drop every entry (oldest first) and reset the statistics, like
# cache_clear(). Dropped entries do not count as evictions.
void lru_clear(lru_cache* c):
	while (c.tail != 0): lru_take(c, c.tail, 0, true)
	c.hits = 0
	c.misses = 0
	c.evictions = 0


void lru_free(lru_cache* c):
	if (c == 0): return
	lru_clear(c)
	c.index.free()
	c.int_index.free()
	free(c)
