# Audited maps keyed by owned values, with checked user hashing and
# equality. keyed_map_new[K, V, H, E](hash, equal) takes two checked function
# values; the compiler requires exactly H = fn[](ref K*) -> int and
# E = fn[](ref K*, ref K*) -> int, so both bodies are analyzed checked code
# that can only read the keys lent to them. The map stores the two code
# addresses and calls them with shared views of its keys. Keys are owned
# by the map and only ever lent shared, so no stored key can change. An
# inconsistent hash or equality can make lookups miss or keys repeat, never
# make memory unsafe: every probe sequence is bounded by the capacity, and
# rehashing reuses the stored hashes without calling user code. V is a sized
# pointer-free value. Metadata, slots and the key destructor stay private.
import lib.safe_owned_vector


type __WKeyedHash = fn(void*) -> int
type __WKeyedEqual = fn(void*, void*) -> int


struct WKeyedMap[K, V]:
	int capacity
	int count
	int used
	K** keys
	V* values
	int* hashes
	char* states
	__WOwnedBufferDrop* drop
	__WKeyedHash* hash
	__WKeyedEqual* equal


struct __WKeyedMapHeader:
	int capacity
	int count
	int used
	void** keys
	void* values
	int* hashes
	char* states
	__WOwnedBufferDrop* drop
	__WKeyedHash* hash
	__WKeyedEqual* equal


# Slot states: 0 empty, 1 full, 2 removed (a tombstone counted in used).
void __w_keyed_map_drop_keys(__WKeyedMapHeader* map):
	for i in range(map.capacity):
		if map.states[i] == 1:
			void* key = map.keys[i]
			map.keys[i] = 0
			map.states[i] = 0
			map.drop(key)
		map.states[i] = 0
	map.count = 0
	map.used = 0


void __w_keyed_map_drop(void* value):
	__WKeyedMapHeader* map = cast(__WKeyedMapHeader*, value)
	__w_keyed_map_drop_keys(map)
	free(cast(void*, map.keys))
	free(map.values)
	free(cast(void*, map.hashes))
	free(map.states)
	free(map)


int __w_keyed_map_hash[K, V](WKeyedMap[K, V]* map, ref K* key):
	int h = map.hash(cast(void*, key))
	return h ^ (h >> 7)


# The slot holding a key equal to key (hash h), or -1.
int __w_keyed_map_find[K, V](WKeyedMap[K, V]* map, ref K* key, int h):
	if map.capacity == 0: return -1
	int mask = map.capacity - 1
	int i = h & mask
	for probes in range(map.capacity):
		int state = map.states[i]
		if state == 0: return -1
		if (state == 1) && (map.hashes[i] == h):
			if map.equal(cast(void*, map.keys[i]), cast(void*, key)): return i
		i = (i + 1) & mask
	return -1


# Grow (dropping tombstones) so that one more slot can be used. Size
# overflow and allocation failure trap before any field changes.
void __w_keyed_map_reserve[K, V](WKeyedMap[K, V]* map):
	if ((map.used + 1) * 4 <= map.capacity * 3): return
	int capacity = 8
	while capacity * 3 < (map.count + 1) * 8: capacity = __w_size_mul(capacity, 2)
	K** keys = cast(K**, __w_new_object(__w_size_mul(capacity, __word_size__)))
	V* values = cast(V*, __w_new_object(__w_size_mul(capacity, sizeof(V))))
	int* hashes = cast(int*, __w_new_object(__w_size_mul(capacity, __word_size__)))
	char* states = cast(char*, __w_new_object(capacity))
	for i in range(capacity): states[i] = 0
	int mask = capacity - 1
	for j in range(map.capacity):
		if map.states[j] == 1:
			int i = map.hashes[j] & mask
			while states[i] != 0: i = (i + 1) & mask
			keys[i] = map.keys[j]
			values[i] = map.values[j]
			hashes[i] = map.hashes[j]
			states[i] = 1
	free(cast(void*, map.keys))
	free(cast(void*, map.values))
	free(cast(void*, map.hashes))
	free(map.states)
	map.keys = keys
	map.values = values
	map.hashes = hashes
	map.states = states
	map.capacity = capacity
	map.used = map.count


own WKeyedMap[K, V]* keyed_map_new[K, V, H, E](H* hash, E* equal):
	WKeyedMap[K, V]* map = cast(WKeyedMap[K, V]*, __w_new_object(sizeof(WKeyedMap[K, V])))
	map.capacity = 0
	map.count = 0
	map.used = 0
	map.keys = 0
	map.values = 0
	map.hashes = 0
	map.states = 0
	map.drop = cast(__WOwnedBufferDrop*, __w_owned_buffer_drop_element[K])
	map.hash = cast(__WKeyedHash*, hash)
	map.equal = cast(__WKeyedEqual*, equal)
	return cast(own WKeyedMap[K, V]*, map)


int keyed_map_length[K, V](ref WKeyedMap[K, V]* value):
	WKeyedMap[K, V]* map = cast(WKeyedMap[K, V]*, value)
	return map.count


int keyed_map_contains[K, V](ref WKeyedMap[K, V]* value, ref K* key):
	WKeyedMap[K, V]* map = cast(WKeyedMap[K, V]*, value)
	return __w_keyed_map_find[K, V](map, key, __w_keyed_map_hash[K, V](map, key)) >= 0


# Consumes key. A new key is stored with element and the result is absent.
# When an equal key is already stored, its value is replaced, the stored key
# is kept and the argument is returned to the caller.
optown K* keyed_map_insert[K, V](refmut WKeyedMap[K, V]* value, own K* key, V element):
	WKeyedMap[K, V]* map = cast(WKeyedMap[K, V]*, value)
	K* raw = cast(K*, key)
	ref K* probe = cast(ref K*, raw)
	int h = __w_keyed_map_hash[K, V](map, probe)
	int found = __w_keyed_map_find[K, V](map, probe, h)
	K** home = cast(K**, &key)
	*home = cast(K*, 0)
	if found >= 0:
		map.values[found] = element
		return cast(optown K*, raw)
	__w_keyed_map_reserve[K, V](map)
	int mask = map.capacity - 1
	int i = h & mask
	while map.states[i] == 1: i = (i + 1) & mask
	if map.states[i] == 0: map.used += 1
	map.keys[i] = raw
	map.values[i] = element
	map.hashes[i] = h
	map.states[i] = 1
	map.count += 1
	return cast(optown K*, 0)


V keyed_map_get[K, V](ref WKeyedMap[K, V]* value, ref K* key):
	WKeyedMap[K, V]* map = cast(WKeyedMap[K, V]*, value)
	int found = __w_keyed_map_find[K, V](map, key, __w_keyed_map_hash[K, V](map, key))
	if found < 0: __w_trap(c"keyed map key not found")
	return map.values[found]


V keyed_map_get_or[K, V](ref WKeyedMap[K, V]* value, ref K* key, V fallback):
	WKeyedMap[K, V]* map = cast(WKeyedMap[K, V]*, value)
	int found = __w_keyed_map_find[K, V](map, key, __w_keyed_map_hash[K, V](map, key))
	if found < 0: return fallback
	return map.values[found]


optref[a] V* keyed_map_find[K, V](ref[a] WKeyedMap[K, V]* value, ref K* key):
	WKeyedMap[K, V]* map = cast(WKeyedMap[K, V]*, value)
	int found = __w_keyed_map_find[K, V](map, key, __w_keyed_map_hash[K, V](map, key))
	if found < 0: return cast(optref[a] V*, 0)
	return cast(optref[a] V*, &map.values[found])


# Removes an equal key and returns its ownership; absent when none matched.
optown K* keyed_map_take[K, V](refmut WKeyedMap[K, V]* value, ref K* key):
	WKeyedMap[K, V]* map = cast(WKeyedMap[K, V]*, value)
	int found = __w_keyed_map_find[K, V](map, key, __w_keyed_map_hash[K, V](map, key))
	if found < 0: return cast(optown K*, 0)
	K* stored = map.keys[found]
	map.keys[found] = cast(K*, 0)
	map.states[found] = 2
	map.count -= 1
	return cast(optown K*, stored)


# Removes and destroys an equal key; 1 when one was removed.
int keyed_map_remove[K, V](refmut WKeyedMap[K, V]* value, ref K* key):
	WKeyedMap[K, V]* map = cast(WKeyedMap[K, V]*, value)
	int found = __w_keyed_map_find[K, V](map, key, __w_keyed_map_hash[K, V](map, key))
	if found < 0: return 0
	void* stored = cast(void*, map.keys[found])
	map.keys[found] = cast(K*, 0)
	map.states[found] = 2
	map.count -= 1
	map.drop(stored)
	return 1


void keyed_map_clear[K, V](refmut WKeyedMap[K, V]* value):
	__w_keyed_map_drop_keys(cast(__WKeyedMapHeader*, value))
