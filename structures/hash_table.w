/*
Shared runtime for built-in map[K, V] and set[K].

The compiler lowers built-in syntax to these helpers. Keys and values are
stored as words in the MVP; small scalar values occupy the low bits. String
keys are cloned so map/set ownership does not depend on literal or stack
lifetimes.
*/
import lib.memory


int __w_strlen(char* c):
	int length = 0
	while(c[length]):
		length = length + 1
	return length


char* __w_strcpy(char *dst, char *src):
	while (src[0]):
		dst[0] = src[0]
		src = src + 1
		dst = dst + 1
	dst[0] = 0
	return dst


int __w_strcmp(char* s1, char* s2):
	int i = 0
	while (s1[i] == s2[i]):
		if (s1[i] == 0):
			return 0
		i = i + 1
	return s1[i] - s2[i]


char* __w_strclone(char *c):
	char *clone = malloc(__w_strlen(c) + 1)
	__w_strcpy(clone, c)
	return clone


void __w_assert(int condition):
	if (condition == 0):
		exit(1)


struct __w_hash_table:
	int capacity
	int count
	int key_kind
	int value_size
	int* keys
	int* values
	char* states


int __w_hash_key_word():
	return 1


int __w_hash_key_cstr():
	return 2


int __w_hash_key_string():
	return 3


int __w_hash_bytes(int data, int length):
	int h = 5381
	int i = 0
	while (i < length):
		h = h * 33 + data[i]
		i = i + 1
	return h


int __w_hash_key_hash(int kind, int key):
	if (kind == __w_hash_key_cstr()):
		return __w_hash_bytes(key, __w_strlen(cast(char*, key)))
	if (kind == __w_hash_key_string()):
		return __w_hash_bytes(load_int(cast(char*, key)), load_int(key + __word_size__))
	return key * 33


int __w_hash_string_equal(int left, int right):
	int left_len = load_int(left + __word_size__)
	int right_len = load_int(right + __word_size__)
	if (left_len != right_len):
		return 0
	int left_data = load_int(cast(char*, left))
	int right_data = load_int(cast(char*, right))
	int i = 0
	while (i < left_len):
		if (left_data[i] != right_data[i]):
			return 0
		i = i + 1
	return 1


int __w_hash_key_equal(int kind, int left, int right):
	if (kind == __w_hash_key_cstr()):
		return __w_strcmp(cast(char*, left), cast(char*, right)) == 0
	if (kind == __w_hash_key_string()):
		return __w_hash_string_equal(left, right)
	return left == right


int __w_hash_clone_string(int key):
	int length = load_int(key + __word_size__)
	char* clone = malloc(2 * __word_size__ + length + 1)
	int data = clone + 2 * __word_size__
	save_int(clone, data)
	save_int(clone + __word_size__, length)
	int source = load_int(cast(char*, key))
	int i = 0
	while (i < length):
		data[i] = source[i]
		i = i + 1
	data[length] = 0
	return cast(int, clone)


int __w_hash_key_clone(int kind, int key):
	if (kind == __w_hash_key_cstr()):
		return cast(int, __w_strclone(cast(char*, key)))
	if (kind == __w_hash_key_string()):
		return __w_hash_clone_string(key)
	return key


void __w_hash_key_free(int kind, int key):
	if ((kind == __w_hash_key_cstr()) | (kind == __w_hash_key_string())):
		free(cast(void*, key))


__w_hash_table* __w_hash_table_new(int key_kind, int value_size, int capacity):
	if (capacity < 16):
		capacity = 16
	__w_hash_table* table = malloc(7 * __word_size__)
	table.capacity = capacity
	table.count = 0
	table.key_kind = key_kind
	table.value_size = value_size
	table.keys = malloc(capacity * __word_size__)
	table.values = malloc(capacity * __word_size__)
	table.states = malloc(capacity)
	int i = 0
	while (i < capacity):
		table.keys[i] = 0
		table.values[i] = 0
		table.states[i] = 0
		i = i + 1
	return table


int __w_hash_table_slot(__w_hash_table* table, int key):
	int mask = table.capacity - 1
	int i = __w_hash_key_hash(table.key_kind, key) & mask
	int first_deleted = -1
	while (table.states[i] != 0):
		if (table.states[i] == 1):
			if (__w_hash_key_equal(table.key_kind, table.keys[i], key)):
				return i
		else if (first_deleted < 0):
			first_deleted = i
		i = (i + 1) & mask
	if (first_deleted >= 0):
		return first_deleted
	return i


void __w_hash_table_set_owned(__w_hash_table* table, int key, int value):
	int i = __w_hash_table_slot(table, key)
	if (table.states[i] != 1):
		table.states[i] = 1
		table.keys[i] = key
		table.count = table.count + 1
	table.values[i] = value


void __w_hash_table_grow(__w_hash_table* table):
	int old_capacity = table.capacity
	int* old_keys = table.keys
	int* old_values = table.values
	char* old_states = table.states

	table.capacity = old_capacity * 2
	table.count = 0
	table.keys = malloc(table.capacity * __word_size__)
	table.values = malloc(table.capacity * __word_size__)
	table.states = malloc(table.capacity)
	int i = 0
	while (i < table.capacity):
		table.keys[i] = 0
		table.values[i] = 0
		table.states[i] = 0
		i = i + 1

	i = 0
	while (i < old_capacity):
		if (old_states[i] == 1):
			__w_hash_table_set_owned(table, old_keys[i], old_values[i])
		i = i + 1
	free(old_keys)
	free(old_values)
	free(old_states)


__w_hash_table* __w_map_new(int key_kind, int value_size):
	return __w_hash_table_new(key_kind, value_size, 16)


void __w_map_set(__w_hash_table* table, int key, int value):
	if (table.count * 4 >= table.capacity * 3):
		__w_hash_table_grow(table)
	int i = __w_hash_table_slot(table, key)
	if (table.states[i] != 1):
		table.states[i] = 1
		table.keys[i] = __w_hash_key_clone(table.key_kind, key)
		table.count = table.count + 1
	table.values[i] = value


int __w_map_contains(__w_hash_table* table, int key):
	int i = __w_hash_table_slot(table, key)
	return table.states[i] == 1


int __w_map_get(__w_hash_table* table, int key):
	int i = __w_hash_table_slot(table, key)
	__w_assert(table.states[i] == 1)
	return table.values[i]


int __w_map_remove(__w_hash_table* table, int key):
	int i = __w_hash_table_slot(table, key)
	if (table.states[i] != 1):
		return 0
	__w_hash_key_free(table.key_kind, table.keys[i])
	table.keys[i] = 0
	table.values[i] = 0
	table.states[i] = 2
	table.count = table.count - 1
	return 1


int __w_map_length(__w_hash_table* table):
	return table.count


int __w_map_iter_find(__w_hash_table* table, int cursor):
	while (cursor < table.capacity):
		if (table.states[cursor] == 1):
			return cursor
		cursor = cursor + 1
	return cursor


int __w_map_iter_begin(__w_hash_table* table):
	return __w_map_iter_find(table, 0)


int __w_map_iter_done(__w_hash_table* table, int cursor):
	return cursor >= table.capacity


int __w_map_iter_next(__w_hash_table* table, int cursor):
	return __w_map_iter_find(table, cursor + 1)


int __w_map_iter_key(__w_hash_table* table, int cursor):
	__w_assert(cursor < table.capacity)
	__w_assert(table.states[cursor] == 1)
	return table.keys[cursor]


void __w_map_free(__w_hash_table* table):
	int i = 0
	while (i < table.capacity):
		if (table.states[i] == 1):
			__w_hash_key_free(table.key_kind, table.keys[i])
		i = i + 1
	free(table.keys)
	free(table.values)
	free(table.states)
	free(table)


__w_hash_table* __w_set_new(int key_kind):
	return __w_map_new(key_kind, 0)


void __w_set_add(__w_hash_table* table, int key):
	__w_map_set(table, key, 1)


int __w_set_contains(__w_hash_table* table, int key):
	return __w_map_contains(table, key)


int __w_set_remove(__w_hash_table* table, int key):
	return __w_map_remove(table, key)


int __w_set_length(__w_hash_table* table):
	return __w_map_length(table)


void __w_set_free(__w_hash_table* table):
	__w_map_free(table)
