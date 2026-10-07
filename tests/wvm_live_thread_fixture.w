# wbuild: binary=wvm_live_thread_fixture arch=x64
import lib.thread
import lib.assert
import lib.time

thread_local int live_thread_tls
int[3] live_thread_ready
int[3] live_thread_answers
int live_thread_release


void live_thread_worker(void* argument):
	int id = *cast(int*, argument)
	live_thread_tls = syscall(186, 0, 0, 0)
	live_thread_ready[id] = 1
	timespec duration
	duration.seconds = 1
	duration.nanoseconds = 0
	while (live_thread_release == 0):
		int result = sys_futex(cast(int, &live_thread_release), 128, 0, cast(int, &duration))
		asserts(c"checkpoint futex result", result == 0 || result == -11 || result == -110)
	assert_equal(live_thread_tls, syscall(186, 0, 0, 0))
	live_thread_answers[id] = 10 + id


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc == 2 && strcmp(args[1], c"timeout") == 0):
		int word = 0
		timespec duration
		duration.seconds = 0
		duration.nanoseconds = 50000000
		assert_equal(-110, sys_futex(cast(int, &word), 128, 0, cast(int, &duration)))
		println(c"timeout")
		return 11
	live_thread_tls = 99
	int[3] ids
	ids[0] = 0
	ids[1] = 1
	ids[2] = 2
	wthread*[2] workers
	for i in range(2):
		workers[i] = thread_spawn(live_thread_worker, cast(void*, &ids[i]))
		asserts(c"checkpoint workers", workers[i] != 0)
	while (live_thread_ready[0] == 0 || live_thread_ready[1] == 0): syscall(24, 0, 0, 0)
	syscall(24, 0, 0, 0)
	assert_equal(7, write(1, c"threads", 7))
	live_thread_release = 1
	asserts(c"wake checkpointed waiters", sys_futex(cast(int, &live_thread_release), 129, 2, 0) >= 0)
	for i in range(2): assert_equal(0, thread_join(workers[i]))
	assert_equal(10, live_thread_answers[0])
	assert_equal(11, live_thread_answers[1])
	wthread* reused = thread_spawn(live_thread_worker, cast(void*, &ids[2]))
	asserts(c"restore preserves reusable thread slots", reused != 0)
	assert_equal(0, thread_join(reused))
	assert_equal(12, live_thread_answers[2])
	assert_equal(99, live_thread_tls)
	println(c"done")
	return 9
