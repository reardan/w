import lib.testing
import lib.net
import lib.event_loop


/* Timer callbacks record firing order in a shared log. */

struct loop_test_log:
	int count
	int first_id
	int second_id
	event_loop* loop


void loop_test_record(int timer_id, void* ctx):
	loop_test_log* log = cast(loop_test_log*, ctx)
	if (log.count == 0):
		log.first_id = timer_id
	else if (log.count == 1):
		log.second_id = timer_id
	log.count = log.count + 1


void loop_test_record_and_stop(int timer_id, void* ctx):
	loop_test_record(timer_id, ctx)
	loop_test_log* log = cast(loop_test_log*, ctx)
	event_loop_stop(log.loop)


void test_timers_fire_in_deadline_order():
	event_loop* loop = event_loop_new()
	loop_test_log* log = new loop_test_log()
	log.count = 0
	log.loop = loop

	int slow = event_loop_add_timer(loop, 40, loop_test_record_and_stop, cast(void*, log))
	int fast = event_loop_add_timer(loop, 5, loop_test_record, cast(void*, log))
	assert_equal(0, event_loop_run(loop))

	assert_equal(2, log.count)
	assert_equal(fast, log.first_id)
	assert_equal(slow, log.second_id)

	free(cast(char*, log))
	event_loop_free(loop)


void test_cancelled_timer_does_not_fire():
	event_loop* loop = event_loop_new()
	loop_test_log* log = new loop_test_log()
	log.count = 0
	log.loop = loop

	int doomed = event_loop_add_timer(loop, 5, loop_test_record, cast(void*, log))
	int keeper = event_loop_add_timer(loop, 20, loop_test_record_and_stop, cast(void*, log))
	assert_equal(1, event_loop_cancel_timer(loop, doomed))
	# Cancelling twice reports failure.
	assert_equal(0, event_loop_cancel_timer(loop, doomed))

	assert_equal(0, event_loop_run(loop))
	assert_equal(1, log.count)
	assert_equal(keeper, log.first_id)

	free(cast(char*, log))
	event_loop_free(loop)


void loop_test_count_to_three(int timer_id, void* ctx):
	loop_test_log* log = cast(loop_test_log*, ctx)
	log.count = log.count + 1
	if (log.count == 3):
		event_loop_cancel_timer(log.loop, timer_id)
		event_loop_stop(log.loop)


void test_interval_timer_repeats():
	event_loop* loop = event_loop_new()
	loop_test_log* log = new loop_test_log()
	log.count = 0
	log.loop = loop

	event_loop_add_interval(loop, 5, loop_test_count_to_three, cast(void*, log))
	assert_equal(0, event_loop_run(loop))
	assert_equal(3, log.count)

	free(cast(char*, log))
	event_loop_free(loop)


/* Descriptor callbacks. */

struct loop_test_io:
	int fd
	int revents
	int reads
	event_loop* loop


void loop_test_on_readable(int fd, int revents, void* ctx):
	loop_test_io* io = cast(loop_test_io*, ctx)
	io.fd = fd
	io.revents = revents
	io.reads = io.reads + 1
	char* buf = malloc(16)
	read(fd, buf, 16)
	free(buf)
	event_loop_remove_fd(io.loop, fd)
	event_loop_stop(io.loop)


void test_fd_callback_on_readable():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)

	event_loop* loop = event_loop_new()
	loop_test_io* io = new loop_test_io()
	io.reads = 0
	io.loop = loop
	event_loop_add_fd(loop, fds[1], poll_in(), loop_test_on_readable, cast(void*, io))

	assert_equal(4, write(fds[0], c"ping", 4))
	assert_equal(0, event_loop_run(loop))

	assert_equal(1, io.reads)
	assert_equal(fds[1], io.fd)
	assert_equal(poll_in(), io.revents & poll_in())

	free(cast(char*, io))
	event_loop_free(loop)
	close(fds[0])
	close(fds[1])
	free(fds)


/* Request timeout pattern: a timer fires because the peer never writes,
   and the response callback would have cancelled it. */

struct loop_test_timeout:
	int timed_out
	int fd
	event_loop* loop


void loop_test_on_timeout(int timer_id, void* ctx):
	loop_test_timeout* state = cast(loop_test_timeout*, ctx)
	state.timed_out = 1
	event_loop_remove_fd(state.loop, state.fd)
	event_loop_stop(state.loop)


void loop_test_unexpected_read(int fd, int revents, void* ctx):
	asserts(c"descriptor became readable but nobody wrote", 0)


void test_timeout_fires_when_peer_is_silent():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)

	event_loop* loop = event_loop_new()
	loop_test_timeout* state = new loop_test_timeout()
	state.timed_out = 0
	state.fd = fds[1]
	state.loop = loop

	event_loop_add_fd(loop, fds[1], poll_in(), loop_test_unexpected_read, cast(void*, state))
	event_loop_add_timer(loop, 30, loop_test_on_timeout, cast(void*, state))

	assert_equal(0, event_loop_run(loop))
	assert_equal(1, state.timed_out)

	free(cast(char*, state))
	event_loop_free(loop)
	close(fds[0])
	close(fds[1])
	free(fds)


void test_run_once_returns_zero_when_idle():
	int* fds = malloc(__word_size__ * 2)
	asserts(c"socket_pair failed", socket_pair(fds) >= 0)

	event_loop* loop = event_loop_new()
	loop_test_io* io = new loop_test_io()
	io.reads = 0
	io.loop = loop
	event_loop_add_fd(loop, fds[1], poll_in(), loop_test_on_readable, cast(void*, io))

	assert_equal(0, event_loop_run_once(loop, 0))
	assert_equal(0, io.reads)

	free(cast(char*, io))
	event_loop_free(loop)
	close(fds[0])
	close(fds[1])
	free(fds)


void test_run_returns_when_nothing_is_watched():
	event_loop* loop = event_loop_new()
	assert_equal(0, event_loop_run(loop))
	event_loop_free(loop)
