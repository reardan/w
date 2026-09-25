# Event-loop scaling benchmark for the task runtime
# (docs/projects/async.md, stage 5). Opens N idle socket pairs, each
# with a task parked reading it, then pushes M messages through one
# active pair while the idle ones stay parked, on the epoll backend and
# on the poll backend. With poll every wakeup rescans all N fds; with
# epoll it only touches the ready one.
#
#   bin/wv2 examples/web/task_bench.w -o bin/task_bench
#   bin/task_bench [idle_pairs] [messages]
import lib.lib
import lib.net
import lib.time
import lib.task
import lib.task_io
import lib.event_loop


generator int idle_reader(int fd):
	char[8] buf
	# Parks until the pair is closed at the end of the run.
	task_read(fd, &buf[0], 8)


generator int ping(int fd, int messages):
	char[1] b
	b[0] = 120
	for i in range(messages):
		task_write_all(fd, &b[0], 1)
		task_read_exact(fd, &b[0], 1)


generator int pong(int fd, int messages):
	char[1] b
	for i in range(messages):
		task_read_exact(fd, &b[0], 1)
		task_write_all(fd, &b[0], 1)


generator int closer(int* fds, int pairs, task* until):
	task_join(until)
	for i in range(pairs):
		close(fds[2 * i])


int run(int use_poll, int pairs, int messages):
	task_scheduler* s = task_scheduler_new()
	if (use_poll):
		event_loop_free(s.loop)
		s.loop = event_loop_new_poll()
	int* fds = cast(int*, malloc(2 * pairs * __word_size__))
	int i = 0
	while (i < pairs):
		asserts(c"socket_pair failed (raise ulimit -n)", socket_pair(&fds[2 * i]) >= 0)
		socket_set_nonblocking(fds[2 * i + 1])
		task_spawn(s, idle_reader(fds[2 * i + 1]))
		i = i + 1
	int* active = cast(int*, malloc(2 * __word_size__))
	socket_pair(active)
	socket_set_nonblocking(active[0])
	socket_set_nonblocking(active[1])
	# Let every idle reader park first.
	task_run_once(s, 0)
	int start = time_monotonic_ms()
	task* p = task_spawn(s, ping(active[0], messages))
	task_spawn(s, pong(active[1], messages))
	task_spawn(s, closer(fds, pairs, p))
	task_run(s)
	int elapsed = time_monotonic_ms() - start
	i = 0
	while (i < pairs):
		close(fds[2 * i + 1])
		i = i + 1
	close(active[0])
	close(active[1])
	free(cast(void*, fds))
	free(cast(void*, active))
	task_scheduler_free(s)
	return elapsed


int main(int argc, int argv):
	char** args = cast(char**, argv)
	int pairs = 2000
	int messages = 5000
	if (argc > 1):
		pairs = atoi(args[1])
	if (argc > 2):
		messages = atoi(args[2])
	print(c"idle tasks: ")
	print(itoa(pairs))
	print(c", round trips: ")
	println(itoa(messages))
	print(c"epoll: ")
	print(itoa(run(0, pairs, messages)))
	println(c" ms")
	print(c"poll:  ")
	print(itoa(run(1, pairs, messages)))
	println(c" ms")
	return 0
