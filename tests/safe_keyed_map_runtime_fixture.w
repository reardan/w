import lib.safe_keyed_map
import lib.safe_owned_vector
import lib.safe_buffer
import lib.memory_debug
import lib.safe


# Owned byte-string keys: hashing and equality only read the lent keys.
struct Name:
	own WByteString* text
	int salt


int name_hash(ref Name* key):
	ref WByteString* text = key.text
	int h = key.salt
	for i in range(byte_string_length(text)): h = h * 31 + byte_string_get(text, i)
	return h


int name_equal(ref Name* left, ref Name* right):
	ref WByteString* a = left.text
	ref WByteString* b = right.text
	if (left.salt != right.salt): return 0
	if (byte_string_length(a) != byte_string_length(b)): return 0
	for i in range(byte_string_length(a)):
		if (byte_string_get(a, i) != byte_string_get(b, i)): return 0
	return 1


# Degenerate but checked operations: every key collides, and nothing is
# ever equal. Lookups miss and keys repeat; memory stays safe.
int collide(ref Name* key):
	return 7


int never_equal(ref Name* left, ref Name* right):
	return 0


type NameHash = fn[](ref Name*) -> int
type NameEqual = fn[](ref Name*, ref Name*) -> int


struct Index:
	own WKeyedMap[Name, int]* names
	int id


own Name* name(int letter, int count, int salt):
	own WByteString* text = byte_string_new()
	for i in range(count): byte_string_push(text, letter + i)
	return new Name(text, salt)


int exercise():
	int total = 0
	for round in range(3):
		own WKeyedMap[Name, int]* map = keyed_map_new[Name, int, NameHash, NameEqual](name_hash, name_equal)
		# Growth past several rehashes, with every key inserted twice.
		for i in range(200):
			optown Name* duplicate = keyed_map_insert[Name, int](map, name(65, i % 100 + 1, i % 3), i)
			if (duplicate): total += 1
		own Name* probe = name(65, 3, 2)
		total += keyed_map_get[Name, int](map, probe)
		optref int* found = keyed_map_find[Name, int](map, probe)
		if (found): total += *found
		total += keyed_map_remove[Name, int](map, probe) * 1000
		total += keyed_map_contains[Name, int](map, probe) * 1000
		# Tombstones are reused and skipped by later probes.
		optown Name* again = keyed_map_insert[Name, int](map, name(65, 3, 2), 5)
		total += keyed_map_get[Name, int](map, probe)
		own Name* four = name(65, 4, 0)
		optown Name* taken = keyed_map_take[Name, int](map, four)
		if (taken): total += taken.salt + 10000
		total += keyed_map_length[Name, int](map) * 100000
		own Name* missing = name(66, 1, 0)
		total += keyed_map_get_or[Name, int](map, missing, 7)
		keyed_map_clear[Name, int](map)
		total += keyed_map_length[Name, int](map) + keyed_map_contains[Name, int](map, four)
		# The cleared map is reusable.
		optown Name* fresh = keyed_map_insert[Name, int](map, name(67, 2, 0), 9)
		total += keyed_map_length[Name, int](map)
	own WKeyedMap[Name, int]* odd = keyed_map_new[Name, int, NameHash, NameEqual](collide, never_equal)
	for i in range(50):
		optown Name* duplicate = keyed_map_insert[Name, int](odd, name(65, 2, 0), i)
		if (duplicate): total += 1000000
	own Name* key = name(65, 2, 0)
	total += keyed_map_length[Name, int](odd) + keyed_map_contains[Name, int](odd, key) + keyed_map_remove[Name, int](odd, key)
	# Maps nested in owned storage are destroyed with it.
	own WOwnedBuffer[Index]* indexes = owned_buffer_new[Index](-1)
	for i in range(4):
		own Index* index = new Index(keyed_map_new[Name, int, NameHash, NameEqual](name_hash, name_equal), i)
		for j in range(i + 1):
			optown Name* duplicate = keyed_map_insert[Name, int](index.names, name(70, j + 1, 0), j)
		owned_buffer_push[Index](indexes, index)
	for index in indexes: total += keyed_map_length[Name, int](index.names) * 10
	return total


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = exercise()
	if result != 59733201:
		safe_println_int(result)
		return 1
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
