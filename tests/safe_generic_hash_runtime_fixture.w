import lib.safe_hash
import lib.safe_owned_vector
import lib.memory_debug


struct HashPair:
	int left
	int right


own WMap[int, HashPair]* filled_map():
	own WMap[int, HashPair]* values = map_new[int, HashPair]()
	for i in range(64): map_set[int, HashPair](values, i, HashPair(i, i * 2))
	return values


int exercise_hash():
	int total = 0
	for i in range(30):
		own WMap[int, HashPair]* values = filled_map()
		optref HashPair* view = map_find[int, HashPair](values, 31)
		if view: total += view.left + view.right
		else: return -1
		map_set[int, HashPair](values, 31, HashPair(31, 62))
		own WBuffer[int]* keys = map_keys[int, HashPair](values)
		own WBuffer[HashPair]* copies = map_values[int, HashPair](values)
		map_clear[int, HashPair](values)
		ref int[] key_view = buffer_view[int](keys)
		for j in range(key_view.length): total += key_view[j]
		ref HashPair[] copied = buffer_view[HashPair](copies)
		for j in range(copied.length): total += copied[j].left + copied[j].right
		own WSet[int]* members = set_new[int]()
		for j in range(64):
			set_add[int](members, j)
			set_add[int](members, j)
		for j in range(32):
			if set_remove[int](members, j) != 1: return -2
			if set_contains[int](members, j): return -3
		own WBuffer[int]* remaining = set_values[int](members)
		set_clear[int](members)
		ref int[] remaining_view = buffer_view[int](remaining)
		for j in range(remaining_view.length): total += remaining_view[j]
		optref HashPair* absent = map_find[int, HashPair](values, 31)
		if absent: return -4
		own WOwnedBuffer[WMap[int, HashPair]]* nested = owned_buffer_new[WMap[int, HashPair]](-1)
		owned_buffer_push[WMap[int, HashPair]](nested, filled_map())
		if i % 2 == 0: continue
		owned_buffer_clear[WMap[int, HashPair]](nested)
	return total


int exercise_hash_exits():
	for i in range(3):
		own WMap[int, HashPair]* values = filled_map()
		if i == 1: break
	own WMap[int, HashPair]* replaced = filled_map()
	replaced = filled_map()
	own WMap[int, HashPair]* moved = replaced
	HashPair value = map_get_or[int, HashPair](moved, 99, HashPair(2, 3))
	return value.left + value.right - 5


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	if exercise_hash() != 290310: return 1
	if exercise_hash_exits(): return 2
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
