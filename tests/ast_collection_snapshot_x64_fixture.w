import lib.lib

int main():
	map[int, float64] values = new map[int, float64]
	if ((values.add(1, 1.5)) != 1.5): return 1
	if ((values.add(1)) != 2.5): return 2
	if ((values.add(1, -2)) != 0.5): return 3
	list[float64] snapshot
	snapshot = values.values()
	if (snapshot.length != 1 || snapshot[0] != 0.5): return 4
	values.add(1, 4.25)
	if (snapshot[0] != 0.5 || values[1] != 4.75): return 5
	values.free()
	snapshot.free()
	return 0
