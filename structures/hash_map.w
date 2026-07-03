/*
Open-addressing hash map from C strings to word values.

Linear probing over power-of-two capacities; keys are cloned on insert and
owned by the map. The table grows at 3/4 load so probe chains stay short.
There is no remove: the intended consumers (symbol/type tables, dicts) only
ever add and update.
*/
import lib.lib
import lib.assert


struct hash_map:
	int capacity
	int count
	char** keys
	int* values


# djb2
int hash_map_hash(char* key):
	int h = 5381
	int i = 0
	while (key[i] != 0):
		h = h * 33 + key[i]
		i = i + 1
	return h


# capacity must be a power of two so the hash can be masked
hash_map* hash_map_new_sized(int capacity):
	hash_map* map = malloc(16)
	map.capacity = capacity
	map.count = 0
	map.keys = malloc(capacity * 4)
	map.values = malloc(capacity * 4)
	int i = 0
	while (i < capacity):
		map.keys[i] = 0
		map.values[i] = 0
		i = i + 1
	return map


hash_map* hash_map_new():
	return hash_map_new_sized(16)


# Slot holding key, or the first empty slot in its probe chain.
int hash_map_slot(hash_map* map, char* key):
	int mask = map.capacity - 1
	int i = hash_map_hash(key) & mask
	while (map.keys[i] != 0):
		if (strcmp(map.keys[i], key) == 0):
			return i
		i = (i + 1) & mask
	return i


# Insert without copying the key (grow reuses the already-owned strings).
void hash_map_set_ptr(hash_map* map, char* key, int value):
	int i = hash_map_slot(map, key)
	if (map.keys[i] == 0):
		map.keys[i] = key
		map.count = map.count + 1
	map.values[i] = value


void hash_map_grow(hash_map* map):
	int old_capacity = map.capacity
	char** old_keys = map.keys
	int* old_values = map.values

	map.capacity = old_capacity * 2
	map.count = 0
	map.keys = malloc(map.capacity * 4)
	map.values = malloc(map.capacity * 4)
	int i = 0
	while (i < map.capacity):
		map.keys[i] = 0
		map.values[i] = 0
		i = i + 1

	i = 0
	while (i < old_capacity):
		if (old_keys[i] != 0):
			hash_map_set_ptr(map, old_keys[i], old_values[i])
		i = i + 1

	free(old_keys)
	free(old_values)


void hash_map_set(hash_map* map, char* key, int value):
	if (map.count * 4 >= map.capacity * 3):
		hash_map_grow(map)
	int i = hash_map_slot(map, key)
	if (map.keys[i] == 0):
		map.keys[i] = strclone(key)
		map.count = map.count + 1
	map.values[i] = value


int hash_map_get_default(hash_map* map, char* key, int missing):
	int i = hash_map_slot(map, key)
	if (map.keys[i] == 0):
		return missing
	return map.values[i]


int hash_map_get(hash_map* map, char* key):
	return hash_map_get_default(map, key, 0)


int hash_map_contains(hash_map* map, char* key):
	int i = hash_map_slot(map, key)
	return map.keys[i] != 0


int hash_map_iter_find(hash_map* map, int cursor):
	while (cursor < map.capacity):
		if (map.keys[cursor] != 0):
			return cursor
		cursor = cursor + 1
	return cursor


int hash_map_iter_begin(hash_map* map):
	return hash_map_iter_find(map, 0)


# Do not mutate the map while iterating.
int hash_map_iter_done(hash_map* map, int cursor):
	return cursor >= map.capacity


int hash_map_iter_next(hash_map* map, int cursor):
	return hash_map_iter_find(map, cursor + 1)


# Yields keys; call hash_map_get(map, key) for the value.
int hash_map_iter_value(hash_map* map, int cursor):
	assert1(cursor < map.capacity)
	assert1(map.keys[cursor] != 0)
	return map.keys[cursor]


void hash_map_free(hash_map* map):
	int i = 0
	while (i < map.capacity):
		if (map.keys[i] != 0):
			free(map.keys[i])
		i = i + 1
	free(map.keys)
	free(map.values)
	free(map)
