import lib.lib

struct ast_snapshot_record:
	int number
	int16 tag

int ast_snapshot_order
int ast_snapshot_mark(int n):
	ast_snapshot_order = ast_snapshot_order * 10 + n
	return n

map[int, int] ast_snapshot_receiver(map[int, int] values):
	ast_snapshot_order = ast_snapshot_order * 10 + 1
	return values

T ast_snapshot_identity[T](T value): return value

int main():
	map[int, int] counts = new map[int, int]
	if ((ast_snapshot_receiver(counts).add(ast_snapshot_mark(2), ast_snapshot_mark(3))) != 3): return 1
	if (ast_snapshot_order != 123): return 2
	if ((counts.add(2)) != 4): return 3
	ast_snapshot_order = 0
	if ((counts.add(ast_snapshot_mark(2), ast_snapshot_mark(3))) != 7): return 4
	if (ast_snapshot_order != 23): return 5
	if ((counts.add(3, counts.add(2, -2))) != 5): return 6
	if (counts[2] != 5): return 7
	if (false && counts.add(2, 10)): return 8
	if (counts[2] != 5): return 9
	if (false & counts.add(2, 10)): return 10
	if (counts[2] != 15): return 11
	list[int] keys
	keys = ast_snapshot_receiver(counts).keys()
	list[int] values = counts.values()
	if (ast_snapshot_order != 231): return 12
	if (keys.length != 2 || keys[0] != 2 || keys[1] != 3): return 13
	if (values[0] != 15 || values[1] != 5): return 14
	counts[2] = 99
	counts.remove(3)
	if (values[0] != 15 || values[1] != 5 || keys.length != 2): return 15
	map[int, float32] reals = new map[int, float32]
	if ((reals.add(7, 1.5)) != 1.5): return 16
	if ((reals.add(7)) != 2.5): return 17
	if ((reals.add(7, -2)) != 0.5): return 18
	list[float32] fractions
	fractions = reals.values()
	if (fractions.length != 1 || fractions[0] != 0.5): return 19
	map[int, ast_snapshot_record] records = new map[int, ast_snapshot_record]
	records[4] = ast_snapshot_record(40, 4)
	records[9] = ast_snapshot_record(90, 9)
	list[ast_snapshot_record] copies
	copies = records.values()
	records[4].number = 41
	if (copies[0].number != 40 || copies[1].tag != 9): return 20
	if (ast_snapshot_identity[ast_snapshot_record](copies[0]).number != 40): return 21
	map[string, string] words = new map[string, string]
	words[s"first"] = s"one"
	words[s"second"] = s"two"
	list[string] names
	names = words.keys()
	list[string] texts = words.values()
	words[s"first"] = s"changed"
	if (names[0] != s"first" || names[1] != s"second"): return 22
	if (texts[0] != s"one" || texts[1] != s"two"): return 23
	set[int] members = set[int]{8, 3, 8}
	list[int] snapshot = members.keys()
	members.remove(8)
	if (snapshot.length != 2 || snapshot[0] != 8 || snapshot[1] != 3): return 24
	list[int] empty
	map[int, int] vacant = new map[int, int]
	empty = vacant.values()
	if (empty.length != 0): return 25
	if (f"{counts.add(2):03}" != s"100"): return 26
	counts.free()
	keys.free()
	values.free()
	reals.free()
	fractions.free()
	records.free()
	copies.free()
	words.free()
	names.free()
	texts.free()
	members.free()
	snapshot.free()
	vacant.free()
	empty.free()
	return 0
