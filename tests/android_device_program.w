# Compiled on the Android device by tools/android/compiler_probe.c, then
# loaded into that same app process. No lib.lib._main startup runs here.
import lib.lib
import lib.page_size


export int android_device_program():
	if (os_android() == 0): return -1
	int page = runtime_page_size()
	if (runtime_page_size_valid(page) == 0): return -2
	char* p = cast(char*, malloc(page + 8))
	if (p == 0): return -3
	p[0] = 19
	p[page + 7] = 23
	map[int, int] values = new map[int, int]
	values[1] = p[0]
	values[2] = p[page + 7]
	int answer = values[1] + values[2]
	free(p)
	values.free()
	# Exercise mmap/munmap guard layout at the actual device page size.
	char* guarded = cast(char*, debug_malloc(page + 8))
	if (guarded == 0): return -4
	guarded[page + 7] = 42
	if ((cast(int, guarded) + page + 8) % page != 0): return -5
	if (guarded[page + 7] != answer): return -6
	debug_free(guarded)
	debug_quarantine_reclaim_to(0)
	return answer
