import lib.safe_hash
import lib.safe_keyed_map
import lib.memory_debug
import lib.safe


struct Cursor:
	own int* payload
	int count


int Cursor_iter_begin(ref Cursor* c): return 0


int Cursor_iter_done(ref Cursor* c, int cursor): return cursor >= c.count


int Cursor_iter_next(ref Cursor* c, int cursor): return cursor + 1


ref[a] int* Cursor_iter_value(ref[a] Cursor* c, int cursor): return c.payload


struct Key:
	own int* payload
	int number


int hash(ref Key* key): return key.number


int equal(ref Key* a, ref Key* b): return a.number == b.number


type Hash = fn[](ref Key*) -> int
type Equal = fn[](ref Key*, ref Key*) -> int


own Key* make_key(int number):
	own int* payload = new int
	*payload = number * 3
	return new Key(payload, number)


int search(ref WKeyedMap[Key, int]* map, int wanted):
	for key, value in map:
		own int* scratch = new int
		*scratch = *value
		if key.number == wanted: return *scratch
	return -1


int exercise():
	for repeat in range(20):
		own WKeyedMap[Key, int]* map = keyed_map_new[Key, int, Hash, Equal](hash, equal)
		own WMap[int, int]* plain = map_new[int, int]()
		own WSet[int]* set = set_new[int]()
		for i in range(12):
			optown Key* old = keyed_map_insert[Key, int](map, make_key(i), i * 2)
			map_set[int, int](plain, i, i * 2)
			set_add[int](set, i)
		if search(map, 8) != 16: return 1
		int sum = 0
		for key, value in map:
			if key.number % 2: continue
			own int* copy = new int
			*copy = *value
			defer: sum += *copy
		if sum != 60: return 2
		sum = 0
		for key, value in plain:
			for other in set:
				if key == other: sum += *value
		if sum != 132: return 3
		own int* payload = new int
		*payload = 7
		own Cursor* cursor = new Cursor(payload, 3)
		int seen = 0
		for item in cursor:
			seen += *item
			if seen == 14: break
		if seen != 14: return 4
		cursor.count = 0
		for item in cursor: return 5
		# All loans have ended. Destruction runs recursive key cleanup once.
		keyed_map_clear[Key, int](map)
		map_clear[int, int](plain)
		set_clear[int](set)
		for key in map: return 6
		for key in plain: return 7
		for key in set: return 8
	return 0


int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = exercise()
	if result:
		safe_println_int(result)
		return result
	int after = 0
	unsafe: after = debug_alloc_report_leaks()
	return after - before
