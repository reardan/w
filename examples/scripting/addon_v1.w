int addon_ticks

void on_load():
	host_log(c"v1 loaded")

int on_tick(int frame):
	addon_ticks = addon_ticks + 1
	if (frame == 3): host_set_health(host_get_health() - 10)
	return frame * 2

int on_summary(int unused):
	return on_tick(1000)

int on_query(int i):
	return i & 7
