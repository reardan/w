# POSIX child measurements used by native benchmark drivers. Output goes to
# private files so wait4 can collect rusage without pipe backpressure.
import tools.host_tools
import lib.time
import lib.str

struct hm_sample:
	process* child
	char* stdout_path
	char* stderr_path
	timespec started
	timespec finished
	int[18] usage
	int status
	int timed_out

type hm_preexec_fn = fn() -> void

float hm_elapsed(hm_sample* sample):
	return cast(float, sample.finished.seconds - sample.started.seconds) + cast(float, sample.finished.nanoseconds - sample.started.nanoseconds) / 1000000000.0

hm_sample* hm_start(list[char*] command, char* cwd = 0, char** environment = 0, int error_fd = -1, int inherited = -1, hm_preexec_fn* preexec = 0):
	ht_require(__word_size__ == 8, c"host metrics requires a 64-bit host build")
	char* executable = process_which(command[0])
	ht_require(executable != 0 && process_path_readable(executable), strjoin(c"measurement executable unavailable: ", command[0]))
	char** argv = strv_new(command.length)
	for i in range(command.length): strv_set(argv, i, command[i])
	if (environment == 0): environment = env_current()
	hm_sample* sample = new hm_sample
	char* work = ht_temp()
	sample.stdout_path = path_join(work, c"stdout")
	sample.stderr_path = path_join(work, c"stderr")
	int out = create_file(sample.stdout_path, 384)
	int err = create_file(sample.stderr_path, 384)
	ht_require(out >= 0 && err >= 0, c"cannot open measurement logs")
	clock_gettime(1, cast(int*, &sample.started))
	int pid = fork()
	ht_require(pid >= 0, c"cannot fork measured child")
	if (pid == 0):
		setpgid(0, 0)
		dup2(out, 1)
		if (error_fd >= 0): dup2(error_fd, 2)
		else: dup2(err, 2)
		process_redirect_null(0, 0)
		if (inherited < 3): process_close_from(3)
		else:
			for fd in range(3, inherited): close(fd)
			process_close_from(inherited + 1)
		if (cwd != 0 && chdir(cwd) != 0): exit(126)
		if (preexec != 0): preexec()
		execve(executable, argv, environment)
		exit(127)
	close(out)
	close(err)
	free(cast(void*, argv))
	process* child = new process
	child.pid = pid
	child.stdin_fd = -1
	child.stdout_fd = -1
	child.stderr_fd = -1
	sample.child = child
	if (ht_children == 0): ht_children = new list[process*]
	ht_children.push(child)
	return sample

int hm_poll(hm_sample* sample):
	process* child = sample.child
	if (child.reaped): return 1
	int status = 0
	int result = wait4(child.pid, &status, 1, cast(int, &sample.usage[0]))
	ht_require(result == child.pid || result == 0 || result == -4, c"wait4 failed")
	if (result != child.pid): return 0
	child.status = status
	child.reaped = 1
	sample.status = process_decode_status(status)
	clock_gettime(1, cast(int*, &sample.finished))
	# A coordinator can exit with live grandchildren; its private group must not.
	kill(0 - child.pid, 9)
	return 1

void hm_finish(hm_sample* sample, int timeout = 30000):
	int deadline = process_monotonic_ms() + timeout
	while (!hm_poll(sample)):
		if (process_monotonic_ms() >= deadline):
			sample.timed_out = 1
			process_kill_group(sample.child, 9)
		process_sleep_ms(1)

json_value* hm_metrics(hm_sample* sample, int darwin = 0):
	json_value* result = json_object()
	int* usage = &sample.usage[0]
	int rss = usage[4]
	if (darwin): rss = rss / 1024
	json_object_set(result, c"peak_rss_kib", json_int(rss))
	json_object_set(result, c"user_cpu_s", json_float(cast(float, usage[0]) + cast(float, usage[1]) / 1000000.0))
	json_object_set(result, c"system_cpu_s", json_float(cast(float, usage[2]) + cast(float, usage[3]) / 1000000.0))
	json_object_set(result, c"voluntary_switches", json_int(usage[16]))
	json_object_set(result, c"involuntary_switches", json_int(usage[17]))
	json_object_set(result, c"elapsed_s", json_float(hm_elapsed(sample)))
	return result
