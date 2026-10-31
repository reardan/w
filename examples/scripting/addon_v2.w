int addon_ticks

void on_load():
	host_log(c"v2 loaded")

int on_tick(int frame):
	addon_ticks = addon_ticks + 1
	host_set_health(host_get_health() + 1)
	return frame * 3 + addon_ticks

int on_summary(int unused):
	return on_tick(1000)

int on_query(int i):
	return i & 7

int on_crash(int unused):
	int* p = cast(int*, 0)
	return p[0]

int on_recurse(int depth):
	if (depth == 0): return 0
	return on_recurse(depth - 1) + 1
