import lib.lib

struct ast_map_snapshot_record:
	int x
	int y

int ast_map_method_sequence

map[int, int] ast_map_method_receiver(map[int, int] values):
	ast_map_method_sequence = ast_map_method_sequence * 10 + 1
	return values

int ast_map_method_argument(int n):
	ast_map_method_sequence = ast_map_method_sequence * 10 + n
	return n

int main():
	map[int, int] counts = new map[int, int]
	if (counts.add(5) != 1 || counts.add(5, 3) != 4 || counts.add(5, -2) != 2): return 1
	if (ast_map_method_receiver(counts).add(ast_map_method_argument(2), ast_map_method_argument(3)) != 3): return 2
	if (ast_map_method_sequence != 123): return 3
	keys := counts.keys()
	values := counts.values()
	if (keys.length != 2 || keys[0] != 5 || keys[1] != 2): return 4
	if (values[0] != 2 || values[1] != 3): return 5
	counts[5] = 9
	if (values[0] != 2): return 6
	map[string, float32] fractions = new map[string, float32]
	if (fractions.add(c"first", 1.5) != 1.5): return 7
	if (fractions.add(s"first") != 2.5): return 8
	if (fractions.add(s"first", -0.5) != 2.0): return 9
	float_values := fractions.values()
	if (float_values[0] != 2.0): return 10
	set[int16] small = set[int16]{9, 4}
	small_keys := small.keys()
	if (small_keys[0] != 9 || small_keys[1] != 4): return 11
	records := map[int, ast_map_snapshot_record]{7: ast_map_snapshot_record(8, 9)}
	snapshots := records.values()
	if (snapshots[0].x != 8 || snapshots[0].y != 9): return 12
	snapshots[0].x = 11
	if (records[7].x != 8): return 13
	map[int, bool] flags = new map[int, bool]
	if (!flags.add(1)): return 14
	counts.free()
	keys.free()
	values.free()
	fractions.free()
	float_values.free()
	small.free()
	small_keys.free()
	records.free()
	snapshots.free()
	flags.free()
	return 0
