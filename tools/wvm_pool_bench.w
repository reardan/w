# wbuild: binary=wvm_pool_bench arch=x64
# Linux x64 local measurements, no timing thresholds. RAM pool operations
# are serialized; this is not a concurrent VM fleet benchmark. /proc
# figures describe the whole benchmark process, not isolated guest PSS.
import lib.vmm.pool
import lib.file
import lib.dir
import lib.process


int pool_bench_ns():
	timespec ts
	if (sys_clock_gettime(clock_monotonic, cast(int, &ts)) < 0): return 0
	return ts.seconds * 1000000000 + ts.nanoseconds


int pool_bench_number(char* text, int maximum):
	int result = 0
	int i = 0
	while (text[i]):
		if (text[i] < '0' || text[i] > '9' || result > maximum): return 0
		result = result * 10 + text[i] - '0'
		i = i + 1
	if (result > maximum): return 0
	return result


void pool_bench_metric(string_builder* json, char* key, int value):
	string_append(json, c",\n  \"")
	string_append(json, key)
	string_append(json, c"\": ")
	string_append_int(json, value)


int pool_bench_fds():
	list[dir_entry*] entries = dir_read(c"/proc/self/fd")
	if (entries == 0): return -1
	int count = entries.length
	dir_entries_free(entries)
	return count


int pool_bench_field(char* text, char* key):
	if (text == 0): return -1
	int offset = 0
	int length = strlen(key)
	while (text[offset]):
		int match = 0
		while (match < length && text[offset + match] == key[match]): match = match + 1
		if (match == length):
			offset = offset + length
			while (text[offset] == ' '): offset = offset + 1
			int value = 0
			while (text[offset] >= '0' && text[offset] <= '9'):
				value = value * 10 + text[offset] - '0'
				offset = offset + 1
			return value
		while (text[offset] && text[offset] != '\n'): offset = offset + 1
		if (text[offset]): offset = offset + 1
	return -1


void pool_bench_memory(string_builder* json, char* prefix):
	char* rollup = file_read_text(c"/proc/self/smaps_rollup")
	list[char*] names = new list[char*]
	names.push(c"Rss:")
	names.push(c"Pss:")
	names.push(c"Shared_Clean:")
	names.push(c"Shared_Dirty:")
	names.push(c"Private_Clean:")
	names.push(c"Private_Dirty:")
	for char* name in names:
		string_builder* key = string_from(prefix)
		string_append_char(key, '_')
		string_append_bytes(key, name, strlen(name) - 1)
		string_append(key, c"_kb")
		pool_bench_metric(json, key.data, pool_bench_field(rollup, name))
		string_free(key)
	__w_list_free(cast(__w_list*, names))
	free(rollup)


int pool_bench_percentile(int* values, int count, int percent):
	# Counts are bounded; insertion sorting once is sufficient here.
	for i in range(1, count):
		int value = values[i]
		int j = i - 1
		while (j >= 0 && values[j] > value):
			values[j + 1] = values[j]
			j = j - 1
		values[j + 1] = value
	return values[(count * percent + 99) / 100 - 1]


int main(int argc, char** args):
	if (argc < 4):
		println(c"usage: wvm_pool_bench ELF ITERATIONS(1..10000) CAPACITY(1..256) [GUEST_ARGS...]")
		return 2
	int iterations = pool_bench_number(args[2], 10000)
	int capacity = pool_bench_number(args[3], 256)
	if (iterations == 0 || capacity == 0): return 2
	string_builder* json = string_from(c"{\n  \"benchmark\": \"serialized_cell_ram_pool\"")
	int fds_before = pool_bench_fds()
	pool_bench_memory(json, c"baseline")
	char* image = file_read_text(args[1])
	int fd = open(args[1], 0, 0)
	if (image == 0 || fd < 0): return 2
	int size = file_size(fd)
	close(fd)
	vm_cell* source = cell_new()
	if (source == 0 || cell_elf_load(source, image, size) == 0): return 2
	free(image)
	char** argv = strv_new(argc - 3)
	argv[0] = args[1]
	for i in range(4, argc): argv[i - 3] = args[i]
	if (cell_stack(source, argc - 3, argv) == 0): return 2
	free(cast(void*, argv))
	int start = pool_bench_ns()
	cell_snapshot* snapshot = cell_snapshot_create(source)
	if (snapshot == 0): return 1
	pool_bench_metric(json, c"snapshot_capture_ns", pool_bench_ns() - start)
	pool_bench_metric(json, c"snapshot_stored_pages", snapshot.resident_pages)
	int image_end = source.heap_start
	cell_free(source)
	int* clone_times = malloc(iterations * sizeof(int))
	int* reset_times = malloc(iterations * sizeof(int))
	for i in range(iterations):
		start = pool_bench_ns()
		vm_cell* cell = cell_snapshot_clone(snapshot)
		clone_times[i] = pool_bench_ns() - start
		if (cell == 0): return 1
		cell_free(cell)
	start = pool_bench_ns()
	cell_pool* pool = cell_pool_new(snapshot, capacity)
	if (pool == 0): return 1
	pool_bench_metric(json, c"pool_create_ns", pool_bench_ns() - start)
	cell_snapshot_free(snapshot)
	# Fault in image pages shared by all clones, and a stack page. Keep
	# this bounded to the ELF image extent, not the entire sparse RAM.
	int checksum = 0
	for i in range(capacity):
		vm_cell* cell = cell_pool_acquire(pool)
		int address = CELL_IMAGE_MIN
		while (address < image_end):
			checksum = checksum + cell.ram[address]
			address = address + 4096
		checksum = checksum + cell.ram[CELL_STACK_TOP - 4096]
	pool_bench_memory(json, c"clones_shared")
	for i in range(capacity):
		for page in range(4): pool.cells[i].ram[CELL_STACK_LOW + page * 4096] = i + 1
	pool_bench_memory(json, c"clones_dirty")
	pool_bench_metric(json, c"deliberately_dirtied_pages", capacity * 4)
	for i in range(capacity):
		if (cell_pool_release(pool, pool.cells[i]) == 0): return 1
	pool_bench_memory(json, c"clones_reset")
	fd = kvm_open_system()
	int has_kvm = fd >= 0
	if (has_kvm): close(fd)
	int failures = 0
	int* run_times = malloc(iterations * sizeof(int))
	start = pool_bench_ns()
	for i in range(iterations):
		vm_cell* cell = cell_pool_acquire(pool)
		int run_start = pool_bench_ns()
		if (has_kvm):
			if (cell_run(cell, 5000) == 0 || cell.status != 0): failures = failures + 1
		run_times[i] = pool_bench_ns() - run_start
		cell.ram[CELL_STACK_LOW] = 99
		int reset_start = pool_bench_ns()
		if (cell_pool_release(pool, cell) == 0): return 1
		reset_times[i] = pool_bench_ns() - reset_start
	pool_bench_metric(json, c"execution_and_reuse_total_ns", pool_bench_ns() - start)
	pool_bench_metric(json, c"iterations", iterations)
	pool_bench_metric(json, c"capacity", capacity)
	pool_bench_metric(json, c"kvm_available", has_kvm)
	pool_bench_metric(json, c"guest_nonzero_or_failed", failures)
	pool_bench_metric(json, c"clone_p50_ns", pool_bench_percentile(clone_times, iterations, 50))
	pool_bench_metric(json, c"clone_p95_ns", pool_bench_percentile(clone_times, iterations, 95))
	pool_bench_metric(json, c"reset_p50_ns", pool_bench_percentile(reset_times, iterations, 50))
	pool_bench_metric(json, c"reset_p95_ns", pool_bench_percentile(reset_times, iterations, 95))
	if (has_kvm):
		pool_bench_metric(json, c"run_p50_ns", pool_bench_percentile(run_times, iterations, 50))
		pool_bench_metric(json, c"run_p95_ns", pool_bench_percentile(run_times, iterations, 95))
	pool_bench_metric(json, c"pool_acquisitions", pool.acquisitions)
	pool_bench_metric(json, c"pool_resets", pool.resets)
	pool_bench_metric(json, c"pool_high_water", pool.high_water)
	pool_bench_metric(json, c"touch_checksum", checksum)
	cell_pool_free(pool)
	free(clone_times)
	free(reset_times)
	free(run_times)
	pool_bench_metric(json, c"fds_before", fds_before)
	pool_bench_metric(json, c"fds_after_cleanup", pool_bench_fds())
	pool_bench_memory(json, c"after_cleanup")
	string_append(json, c"\n}\n")
	print(json.data)
	string_free(json)
	if (failures): return 1
	return 0
