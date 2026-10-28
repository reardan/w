# Audited maps/sets with closed integral keys and pointer-free map values.
# Checked identity belongs to the wrapper, never to the legacy table alias.
import structures.hash_table
import lib.safe_vector


struct WMap[K, V]:
	map[K, V] entries


struct WSet[K]:
	set[K] entries


struct __WCheckedHashHeader:
	__w_hash_table* entries


void __w_checked_hash_drop(void* value):
	__WCheckedHashHeader* wrapper = cast(__WCheckedHashHeader*, value)
	__w_map_free(wrapper.entries)
	free(wrapper)


own WMap[K, V]* map_new[K, V]():
	WMap[K, V]* value = cast(WMap[K, V]*, __w_new_object(sizeof(WMap[K, V])))
	value.entries = new map[K, V]
	return cast(own WMap[K, V]*, value)


int map_length[K, V](ref WMap[K, V]* value):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	return map.entries.length


int map_contains[K, V](ref WMap[K, V]* value, K key):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	return key in map.entries


void map_set[K, V](refmut WMap[K, V]* value, K key, V element):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	map.entries[key] = element


V map_get[K, V](ref WMap[K, V]* value, K key):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	return map.entries[key]


V map_get_or[K, V](ref WMap[K, V]* value, K key, V fallback):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	return map.entries.get(key, fallback)


optref[a] V* map_find[K, V](ref[a] WMap[K, V]* value, K key):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	__w_hash_table* table = cast(__w_hash_table*, map.entries)
	int slot = __w_hash_table_slot(table, cast(int, key))
	if table.states[slot] != 1: return 0
	return cast(optref[a] V*, __w_hash_value_addr(table, slot))


int map_remove[K, V](refmut WMap[K, V]* value, K key):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	return map.entries.remove(key)


void map_clear[K, V](refmut WMap[K, V]* value):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	map.entries.free()
	map.entries = new map[K, V]


own WBuffer[K]* map_keys[K, V](ref WMap[K, V]* value):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	own WBuffer[K]* keys = buffer_new[K]()
	for K key in map.entries: buffer_push[K](keys, key)
	return keys


own WBuffer[V]* map_values[K, V](ref WMap[K, V]* value):
	WMap[K, V]* map = cast(WMap[K, V]*, value)
	own WBuffer[V]* values = buffer_new[V]()
	for K key in map.entries: buffer_push[V](values, map.entries[key])
	return values


own WSet[K]* set_new[K]():
	WSet[K]* value = cast(WSet[K]*, __w_new_object(sizeof(WSet[K])))
	value.entries = new set[K]
	return cast(own WSet[K]*, value)


int set_length[K](ref WSet[K]* value):
	WSet[K]* set = cast(WSet[K]*, value)
	return set.entries.length


int set_contains[K](ref WSet[K]* value, K key):
	WSet[K]* set = cast(WSet[K]*, value)
	return key in set.entries


void set_add[K](refmut WSet[K]* value, K key):
	WSet[K]* set = cast(WSet[K]*, value)
	set.entries.add(key)


int set_remove[K](refmut WSet[K]* value, K key):
	WSet[K]* set = cast(WSet[K]*, value)
	return set.entries.remove(key)


void set_clear[K](refmut WSet[K]* value):
	WSet[K]* set = cast(WSet[K]*, value)
	set.entries.free()
	set.entries = new set[K]


own WBuffer[K]* set_values[K](ref WSet[K]* value):
	WSet[K]* set = cast(WSet[K]*, value)
	own WBuffer[K]* values = buffer_new[K]()
	for K key in set.entries: buffer_push[K](values, key)
	return values


# Private traversal used by checked for loops. The compiler retains a shared
# borrow of the wrapper across every implicit read. Slots never escape raw.
int __w_checked_hash_iter_begin(__WCheckedHashHeader* value):
	return __w_map_iter_begin(value.entries)


int __w_checked_hash_iter_done(__WCheckedHashHeader* value, int cursor):
	return __w_map_iter_done(value.entries, cursor)


int __w_checked_hash_iter_next(__WCheckedHashHeader* value, int cursor):
	return __w_map_iter_next(value.entries, cursor)


int __w_checked_hash_iter_key(__WCheckedHashHeader* value, int cursor):
	return __w_map_iter_key(value.entries, cursor)


void* __w_checked_hash_iter_value(__WCheckedHashHeader* value, int cursor):
	return __w_map_iter_value_addr(value.entries, cursor)
