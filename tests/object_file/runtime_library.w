# A W library that keeps its runtime (no --freestanding): containers and
# the allocator are private to the object, as in a --static library,
# and only the exported adapters and this root's globals are global
# symbols (tests/object_file_test.w links it with a C main).
int w_runtime_calls = 0


export int w_distinct(int* xs, int n):
	w_runtime_calls = w_runtime_calls + 1
	set[int] seen = new set[int]
	list[int] order = new list[int]
	for i in range(n):
		if ((xs[i] in seen) == 0):
			seen.add(xs[i])
			order.push(xs[i])
	return order.length


export int w_histogram_max(int* xs, int n):
	w_runtime_calls = w_runtime_calls + 1
	map[int, int] counts = new map[int, int]
	int best = 0
	for i in range(n):
		counts[xs[i]] = counts.get(xs[i], 0) + 1
		if (counts[xs[i]] > best): best = counts[xs[i]]
	return best
