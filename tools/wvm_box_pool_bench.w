# wbuild: binary=wvm_box_pool_bench arch=x64 tag=tests
# Serialized ready-pool measurements. Refill includes destruction and restore;
# acquire merely leases an already-ready guest. No latency thresholds.
import lib.vmm.box_pool
import structures.json
import lib.dir

int box_bench_ns():
	timespec ts
	if (sys_clock_gettime(clock_monotonic, cast(int, &ts)) < 0): return 0
	return ts.seconds * 1000000000 + ts.nanoseconds

int box_bench_fds():
	list[dir_entry*] entries = dir_read(c"/proc/self/fd")
	if (entries == 0): return -1
	int count = entries.length
	dir_entries_free(entries)
	return count

int main(int argc, char** args):
	if (argc < 6):
		println(c"usage: wvm_box_pool_bench KERNEL INITRD ITERATIONS(1..1000) CAPACITY(1..64) COMMAND [ARGS...]")
		return 2
	int iterations = atoi(args[3])
	int capacity = atoi(args[4])
	if (iterations < 1 || iterations > 1000 || capacity < 1 || capacity > 64): return 2
	int fds_before = box_bench_fds()
	vm_box_options* options = box_options_new()
	options.kernel = args[1]
	options.initrd = args[2]
	vm_box_session* source = box_session_open(options)
	free(options)
	if (source == 0): return 1
	int started = box_bench_ns()
	box_snapshot* snapshot = box_snapshot_create_cow(source, 30000)
	int capture_ns = box_bench_ns() - started
	box_session_close(source)
	if (snapshot == 0): return 1
	started = box_bench_ns()
	box_pool* pool = box_pool_new(snapshot, capacity, 60000)
	int pool_create_ns = box_bench_ns() - started
	box_snapshot_free(snapshot)
	if (pool == 0): return 1
	json_value* result = json_object()
	json_object_set(result, c"benchmark", json_string(c"serialized_ready_linux_pool"))
	json_object_set(result, c"capacity", json_int(capacity))
	json_object_set(result, c"capture_ns", json_int(capture_ns))
	json_object_set(result, c"pool_create_ns", json_int(pool_create_ns))
	json_value* acquisitions = json_array()
	json_value* commands = json_array()
	json_value* replacements = json_array()
	int failures = 0
	char** command = strv_new(argc - 5)
	for i in range(5, argc): strv_set(command, i - 5, args[i])
	for i in range(iterations):
		started = box_bench_ns()
		vm_box_session* session = box_pool_acquire(pool)
		json_array_push(acquisitions, json_int(box_bench_ns() - started))
		if (session == 0):
			failures = failures + 1
			break
		started = box_bench_ns()
		process_result* reply = box_session_exec(session, command, c"/", 30000, 4096)
		json_array_push(commands, json_int(box_bench_ns() - started))
		if (reply == 0): failures = failures + 1
		else if (reply.status != 0): failures = failures + 1
		process_result_free(reply)
		started = box_bench_ns()
		int ok = box_pool_release(pool, session)
		json_array_push(replacements, json_int(box_bench_ns() - started))
		if (ok == 0):
			failures = failures + 1
			break
	free(cast(void*, command))
	json_object_set(result, c"acquire_ns", acquisitions)
	json_object_set(result, c"command_ns", commands)
	json_object_set(result, c"destroy_and_refill_ns", replacements)
	json_object_set(result, c"failures", json_int(failures))
	box_pool_free(pool)
	int fds_after = box_bench_fds()
	json_object_set(result, c"fds_before", json_int(fds_before))
	json_object_set(result, c"fds_after", json_int(fds_after))
	char* text = json_stringify(result)
	println(text)
	free(text)
	json_free(result)
	if (fds_before != fds_after): return 1
	return failures != 0
