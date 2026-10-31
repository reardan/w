int on_tick(int frame):
	addon_ticks = addon_ticks + 1
	host_set_health(host_get_health() + 1)
	return frame * 3 + addon_ticks

int on_crash(int unused):
	int* p = cast(int*, 0)
	return p[0]
