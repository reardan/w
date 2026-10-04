# wbuild: binary=wvm_thread_fixture arch=x64
import lib.thread
import lib.assert
import lib.time
import lib.memfd

thread_local int cell_tls
int cell_release
int cell_main_live = 1
int cell_sum
wmutex cell_mutex
char* cell_guarded
int cell_guard_ready


void cell_worker(void* argument):
	int* answer = cast(int*, argument)
	assert_equal(0, cell_tls)
	cell_tls = syscall(186, 0, 0, 0)
	# CPU-only waiting requires timer preemption for the parent to run.
	while (cell_release == 0): pass
	for i in range(500):
		mutex_lock(&cell_mutex)
		int value = cell_sum
		syscall(24, 0, 0, 0) # force contention while holding the mutex
		cell_sum = value + 1
		mutex_unlock(&cell_mutex)
	answer[0] = cell_tls
	assert_equal(cell_tls, syscall(186, 0, 0, 0))


void cell_raw_survivor():
	while (cell_main_live): pass
	println(c"surviving worker")
	thread_exit(23)


void cell_raw_spin():
	while (1): pass


void cell_guard_worker():
	assert_equal(43, cell_guarded[0]) # populate this vCPU's TLB
	cell_guard_ready = 1
	while (cell_release == 0): pass
	# A sibling revoked access while we were preempted. Cached user
	# translations must be invalidated before this vCPU runs again.
	int forbidden = cell_guarded[0]
	thread_exit(forbidden)


int main(int argc, int argv):
	if (argc != 2): return 2
	char** args = cast(char**, argv)
	if (strcmp(args[1], c"threads") == 0):
		cell_tls = 91
		int[3] answers
		wthread*[3] workers
		for i in range(3):
			workers[i] = thread_spawn(cell_worker, cast(void*, &answers[i]))
			asserts(c"create worker", workers[i] != 0)
		cell_release = 1
		for i in range(3): assert_equal(0, thread_join(workers[i]))
		assert_equal(1500, cell_sum)
		assert_equal(91, cell_tls)
		for i in range(3):
			asserts(c"virtual tid differs from main", answers[i] > 1)
			for j in range(i): asserts(c"unique tids", answers[j] != answers[i])
		# Reuse vCPU slots, reset thread-local storage, and reclaim joins.
		for i in range(3):
			wthread* worker = thread_spawn(cell_worker, cast(void*, &answers[i]))
			asserts(c"reuse thread slot", worker != 0)
			thread_join(worker)
		assert_equal(3000, cell_sum)
		println(c"threads OK")
		return 0
	if (strcmp(args[1], c"mainexit") == 0):
		sys_set_tid_address(cast(int, &cell_main_live))
		asserts(c"raw clone", thread_create(cell_raw_survivor) > 1)
		thread_exit(17)
	if (strcmp(args[1], c"group") == 0):
		asserts(c"raw clone", thread_create(cell_raw_spin) > 1)
		syscall(231, 7, 0, 0)
	if (strcmp(args[1], c"spin") == 0):
		asserts(c"raw clone", thread_create(cell_raw_spin) > 1)
		asserts(c"second raw clone", thread_create(cell_raw_spin) > 1)
		cell_raw_spin()
	if (strcmp(args[1], c"limit") == 0):
		asserts(c"first clone", thread_create(cell_raw_spin) > 1)
		assert_equal(-11, thread_create(cell_raw_spin))
		syscall(231, 0, 0, 0)
	if (strcmp(args[1], c"tlb") == 0):
		cell_guarded = cast(char*, mmap(0, 4096, 3, MAP_PRIVATE | MAP_ANONYMOUS))
		cell_guarded[0] = 43
		asserts(c"guard worker", thread_create(cell_guard_worker) > 1)
		while (cell_guard_ready == 0): pass
		assert_equal(0, mprotect(cast(int, cell_guarded), 4096, 0))
		cell_release = 1
		cell_raw_spin()
	if (strcmp(args[1], c"futex") == 0):
		int word = 0
		assert_equal(-11, sys_futex(cast(int, &word), 0, 1, 0))
		assert_equal(-22, sys_futex(cast(int, &word) + 1, 0, 0, 0))
		assert_equal(-14, sys_futex(4096, 0, 0, 0))
		assert_equal(-38, sys_futex(cast(int, &word), 9, 0, 0))
		timespec duration
		duration.seconds = 0
		duration.nanoseconds = 15000000
		word = -1
		duration.nanoseconds = 0
		assert_equal(-110, sys_futex(cast(int, &word), 128, -1, cast(int, &duration)))
		word = 0
		duration.nanoseconds = 15000000
		int start = time_monotonic_ms()
		assert_equal(-110, sys_futex(cast(int, &word), 128, 0, cast(int, &duration)))
		asserts(c"futex timeout elapsed", time_monotonic_ms() - start >= 14)
		println(c"futex OK")
		return 0
	if (strcmp(args[1], c"park") == 0):
		int word = 0
		sys_futex(cast(int, &word), 0, 0, 0)
		return 9
	return 3
